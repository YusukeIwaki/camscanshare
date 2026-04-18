@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import SwiftUI

private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

@MainActor @Observable
final class CameraScanViewModel {
    private struct TimedDetection {
        let rectangle: DetectedRectangle?
        let timestamp: TimeInterval
    }

    private let stableBufferSize = 7
    private let stableMinDetections = 3
    private let holdDuration: TimeInterval = 0.5
    private let smoothingFactor: CGFloat = 0.35

    private let sessionBox = CaptureSessionBox()
    var detectedRectangle: DetectedRectangle?
    var previewImageAspectRatio: CGFloat = 3.0 / 4.0
    var isCapturing = false
    var isFinalizing = false
    var capturedPages: [UIImage] = []
    var latestThumbnail: UIImage?

    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "camera.processing", qos: .userInitiated)
    private let cameraDelegate = CameraDelegate()
    private var isConfigured = false
    private var recentDetections: [TimedDetection] = []
    private var lastValidRectangle: DetectedRectangle?
    private var lastValidTimestamp: TimeInterval = 0

    var session: AVCaptureSession { sessionBox.session }
    var pageCount: Int { capturedPages.count }

    func setupCamera() {
        guard !isConfigured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.beginConfiguration()
        session.sessionPreset = .photo

        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        videoOutput.setSampleBufferDelegate(cameraDelegate, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        session.commitConfiguration()
        isConfigured = true

        cameraDelegate.onRectangleDetected = { [weak self] rect in
            Task { @MainActor [weak self] in
                self?.ingestDetectedRectangle(rect)
            }
        }
        cameraDelegate.onPreviewAspectRatioChanged = { [weak self] aspectRatio in
            Task { @MainActor [weak self] in
                self?.previewImageAspectRatio = aspectRatio
            }
        }
    }

    func startSession() {
        let sessionBox = self.sessionBox
        processingQueue.async {
            sessionBox.session.startRunning()
        }
    }

    func stopSession() {
        let sessionBox = self.sessionBox
        processingQueue.async {
            sessionBox.session.stopRunning()
        }
    }

    func capturePhoto() async -> UIImage? {
        guard !isCapturing else { return nil }
        isCapturing = true

        let settings = AVCapturePhotoSettings()
        let delegate = cameraDelegate
        let photoOutput = self.photoOutput

        let image = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            delegate.photoContinuation = continuation
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }

        isCapturing = false
        return image
    }

    func processAndStoreCapturedImage(_ image: UIImage) {
        let correctedImage = PaperDetectionService.correctDocumentGeometry(image: image)
        capturedPages.append(correctedImage)
        latestThumbnail = correctedImage.preparingThumbnail(of: CGSize(width: 104, height: 104))
    }

    private func ingestDetectedRectangle(_ rectangle: DetectedRectangle?) {
        let now = Date().timeIntervalSinceReferenceDate

        recentDetections.append(TimedDetection(rectangle: rectangle, timestamp: now))
        if recentDetections.count > stableBufferSize {
            recentDetections.removeFirst(recentDetections.count - stableBufferSize)
        }

        let validRectangles = recentDetections.compactMap(\.rectangle)
        if validRectangles.count >= stableMinDetections {
            let median = medianRectangle(validRectangles)
            let smoothed = if let current = detectedRectangle {
                interpolate(from: current, to: median, factor: smoothingFactor)
            } else {
                median
            }
            withAnimation(.easeInOut(duration: 0.15)) {
                detectedRectangle = smoothed
            }
            lastValidRectangle = smoothed
            lastValidTimestamp = now
            return
        }

        if let lastValidRectangle, (now - lastValidTimestamp) < holdDuration {
            withAnimation(.easeInOut(duration: 0.15)) {
                detectedRectangle = lastValidRectangle
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            detectedRectangle = nil
        }
        lastValidRectangle = nil
    }

    private func medianRectangle(_ rectangles: [DetectedRectangle]) -> DetectedRectangle {
        DetectedRectangle(
            topLeft: medianPoint(rectangles.map(\.topLeft)),
            topRight: medianPoint(rectangles.map(\.topRight)),
            bottomLeft: medianPoint(rectangles.map(\.bottomLeft)),
            bottomRight: medianPoint(rectangles.map(\.bottomRight))
        )
    }

    private func medianPoint(_ points: [CGPoint]) -> CGPoint {
        let xs = points.map(\.x).sorted()
        let ys = points.map(\.y).sorted()
        let mid = xs.count / 2
        return CGPoint(x: xs[mid], y: ys[mid])
    }

    private func interpolate(
        from current: DetectedRectangle,
        to target: DetectedRectangle,
        factor: CGFloat
    ) -> DetectedRectangle {
        DetectedRectangle(
            topLeft: interpolate(from: current.topLeft, to: target.topLeft, factor: factor),
            topRight: interpolate(from: current.topRight, to: target.topRight, factor: factor),
            bottomLeft: interpolate(from: current.bottomLeft, to: target.bottomLeft, factor: factor),
            bottomRight: interpolate(from: current.bottomRight, to: target.bottomRight, factor: factor)
        )
    }

    private func interpolate(from current: CGPoint, to target: CGPoint, factor: CGFloat) -> CGPoint {
        CGPoint(
            x: current.x + (target.x - current.x) * factor,
            y: current.y + (target.y - current.y) * factor
        )
    }
}

// MARK: - Camera Delegate (handles AVFoundation callbacks off main actor)

final class CameraDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCapturePhotoCaptureDelegate, @unchecked Sendable
{
    var onRectangleDetected: (@Sendable (DetectedRectangle?) -> Void)?
    var onPreviewAspectRatioChanged: (@Sendable (CGFloat) -> Void)?
    var photoContinuation: CheckedContinuation<UIImage?, Never>?

    private let ciContext = CIContext()
    private let previewDetectionMaxDimension: CGFloat = 640
    private let rectangleDetectionInterval: TimeInterval = 0.12
    private var lastRectangleDetectionTime: TimeInterval = 0

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let portraitAspectRatio = min(width, height) / max(width, height)
        onPreviewAspectRatioChanged?(portraitAspectRatio)

        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastRectangleDetectionTime >= rectangleDetectionInterval else { return }
        lastRectangleDetectionTime = now

        let detected = detectRectangle(in: pixelBuffer)
        onRectangleDetected?(detected)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let image: UIImage?
        if let data = photo.fileDataRepresentation() {
            image = UIImage(data: data)
        } else {
            image = nil
        }
        photoContinuation?.resume(returning: image)
        photoContinuation = nil
    }

    private func detectRectangle(in pixelBuffer: CVPixelBuffer) -> DetectedRectangle? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let scale = min(1.0, previewDetectionMaxDimension / max(ciImage.extent.width, ciImage.extent.height))
        let resized = if scale < 1.0 {
            ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            ciImage
        }

        guard let cgImage = ciContext.createCGImage(resized, from: resized.extent) else {
            return nil
        }
        return PaperDetectionService.detectRectangle(in: UIImage(cgImage: cgImage))
    }
}
