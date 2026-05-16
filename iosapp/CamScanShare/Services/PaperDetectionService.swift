import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

struct DetectedRectangle: Sendable, Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
}

private struct VisionRectangleCandidate {
    let rectangle: DetectedRectangle
    let confidence: Float
    let score: Double
}

enum DocumentOrientation {
    case portrait
    case landscape
}

enum PaperDetectionService {
    private static let a4Portrait = 210.0 / 297.0
    private static let a4Landscape = 297.0 / 210.0
    private static let a4Tolerance = 0.20

    static func createRectangleDetectionRequest(
        completion: @escaping @Sendable (DetectedRectangle?) -> Void
    ) -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest { request, error in
            guard error == nil,
                let rectangleRequest = request as? VNDetectRectanglesRequest
            else {
                completion(nil)
                return
            }
            completion(bestVisionCandidate(from: rectangleRequest.results ?? [], anchorRectangle: nil)?.rectangle)
        }
        configure(request)
        return request
    }

    static func detectRectangle(
        in image: UIImage,
        debugSink: ImageProcessingDebugSink = .shared,
        anchorRectangle: DetectedRectangle? = nil
    ) -> DetectedRectangle? {
        let session = debugSink.startSession(
            category: "paper-detection",
            label: "capture",
            metadata: [
                "inputWidth": "\(Int(image.size.width))",
                "inputHeight": "\(Int(image.size.height))",
                "platform": "ios",
                "anchor": "\(anchorRectangle != nil)"
            ]
        )
        return detectRectangle(in: image, anchorRectangle: anchorRectangle, session: session, debugSink: debugSink)
    }

    private static func detectRectangle(
        in image: UIImage,
        anchorRectangle: DetectedRectangle?,
        session: ImageProcessingDebugSession?,
        debugSink: ImageProcessingDebugSink
    ) -> DetectedRectangle? {
        let startedAt = debugSink.now()
        debugSink.writeImage(session, label: "input", image: image)
        let uprightImage = image.normalizedOrientation()
        guard let cgImage = uprightImage.cgImage else { return nil }

        if session?.isEnabled == true {
            let artifactStartedAt = debugSink.now()
            let debugImages = OpenCVDocumentFilterBridge.documentDetectionDebugImages(in: uprightImage)
            for key in debugImages.keys.sorted() {
                debugSink.writeImage(session, label: key, image: debugImages[key])
            }
            debugSink.recordTimingSince(
                session,
                stage: "paper_detection.debug_artifacts",
                startedAt: artifactStartedAt,
                metadata: ["imageCount": "\(debugImages.count)"]
            )
        }

        let openCVRectangle = rectangleFromOpenCV(in: uprightImage)
        let visionRectangle = rectangleFromVision(cgImage: cgImage, anchorRectangle: anchorRectangle)
        let rectangle: DetectedRectangle?
        let source: String
        if let openCVRectangle, matchesAnchor(openCVRectangle, anchorRectangle) {
            rectangle = openCVRectangle
            source = "opencv"
        } else if let visionRectangle, matchesAnchor(visionRectangle.rectangle, anchorRectangle) {
            rectangle = visionRectangle.rectangle
            source = "vision"
        } else if let anchorRectangle {
            rectangle = anchorRectangle
            source = "preview_anchor"
        } else {
            rectangle = openCVRectangle ?? visionRectangle?.rectangle
            source = rectangle == nil ? "none" : (openCVRectangle == nil ? "vision" : "opencv")
        }
        debugSink.writeText(session, fileName: "selected_quad.json", text: rectangleJson(rectangle))
        debugSink.writeImage(session, label: "selected_quad_overlay", image: drawRectangleOverlay(image: uprightImage, rectangle: rectangle))
        debugSink.recordTimingSince(
            session,
            stage: "paper_detection.total",
            startedAt: startedAt,
            metadata: [
                "result": rectangle == nil ? "none" : "quad",
                "source": source,
                "anchor": "\(anchorRectangle != nil)"
            ]
        )
        return rectangle
    }

    static func correctDocumentGeometry(
        image: UIImage,
        debugSink: ImageProcessingDebugSink = .shared,
        anchorRectangle: DetectedRectangle? = nil
    ) -> UIImage {
        let session = debugSink.startSession(
            category: "document-geometry",
            label: "capture",
            metadata: [
                "inputWidth": "\(Int(image.size.width))",
                "inputHeight": "\(Int(image.size.height))",
                "platform": "ios",
                "anchor": "\(anchorRectangle != nil)"
            ]
        )
        let startedAt = debugSink.now()
        debugSink.writeImage(session, label: "input", image: image)
        let uprightImage = image.normalizedOrientation()
        guard let rectangle = detectRectangle(
            in: uprightImage,
            anchorRectangle: anchorRectangle,
            session: session,
            debugSink: debugSink
        ),
            let step0 = correctPerspective(image: uprightImage, rectangle: rectangle)
        else {
            debugSink.recordTimingSince(
                session,
                stage: "document_geometry.total",
                startedAt: startedAt,
                metadata: ["result": "fallback_upright"]
            )
            return uprightImage
        }
        debugSink.writeText(session, fileName: "input_corners.json", text: rectangleJson(rectangle))
        debugSink.writeImage(session, label: "warped_rgba", image: step0)
        let normalized = normalizeDocumentAspect(step0, rectangle: rectangle)
        debugSink.writeImage(session, label: "output", image: normalized)
        debugSink.recordTimingSince(
            session,
            stage: "document_geometry.total",
            startedAt: startedAt,
            metadata: [
                "result": "corrected",
                "outputWidth": "\(Int(normalized.size.width))",
                "outputHeight": "\(Int(normalized.size.height))"
            ]
        )
        return normalized
    }

    static func correctPerspective(
        image: UIImage, rectangle: DetectedRectangle
    ) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }
        let imageSize = ciImage.extent.size

        // Convert normalized Vision coordinates to CIImage coordinates
        let tl = CGPoint(x: rectangle.topLeft.x * imageSize.width, y: rectangle.topLeft.y * imageSize.height)
        let tr = CGPoint(
            x: rectangle.topRight.x * imageSize.width, y: rectangle.topRight.y * imageSize.height)
        let bl = CGPoint(
            x: rectangle.bottomLeft.x * imageSize.width, y: rectangle.bottomLeft.y * imageSize.height)
        let br = CGPoint(
            x: rectangle.bottomRight.x * imageSize.width, y: rectangle.bottomRight.y * imageSize.height)

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = tl
        filter.topRight = tr
        filter.bottomLeft = bl
        filter.bottomRight = br

        guard let outputImage = filter.outputImage else { return nil }
        let context = CIContext()
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func normalizeDocumentAspect(
        _ image: UIImage,
        rectangle: DetectedRectangle
    ) -> UIImage {
        guard let targetRatio = targetPaperRatio(for: rectangle) else {
            return image
        }

        let targetSize = normalizedSize(for: image.size, targetRatio: targetRatio)
        let targetWidth = max(1, Int(round(targetSize.width)))
        let targetHeight = max(1, Int(round(targetSize.height)))

        guard targetWidth != Int(image.size.width) || targetHeight != Int(image.size.height) else {
            return image
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: targetWidth, height: targetHeight),
            format: format
        )
        return renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }
    }

    static func targetPaperRatio(for rectangle: DetectedRectangle) -> Double? {
        let widthTop = distance(rectangle.topLeft, rectangle.topRight)
        let widthBottom = distance(rectangle.bottomLeft, rectangle.bottomRight)
        let heightLeft = distance(rectangle.topLeft, rectangle.bottomLeft)
        let heightRight = distance(rectangle.topRight, rectangle.bottomRight)
        return targetPaperRatio(
            widthTop: widthTop,
            widthBottom: widthBottom,
            heightLeft: heightLeft,
            heightRight: heightRight
        )
    }

    static func targetPaperRatio(
        widthTop: Double,
        widthBottom: Double,
        heightLeft: Double,
        heightRight: Double
    ) -> Double? {
        guard let orientation = estimatedOrientation(
            widthTop: widthTop,
            widthBottom: widthBottom,
            heightLeft: heightLeft,
            heightRight: heightRight
        ) else {
            return nil
        }

        let estimatedShortLongRatio = estimatedShortLongRatio(
            widthTop: widthTop,
            widthBottom: widthBottom,
            heightLeft: heightLeft,
            heightRight: heightRight
        )
        let portraitDelta = abs(estimatedShortLongRatio / a4Portrait - 1.0)
        guard portraitDelta <= a4Tolerance else { return nil }
        return orientation == .portrait ? a4Portrait : a4Landscape
    }

    static func normalizedSize(for imageSize: CGSize, targetRatio: Double) -> CGSize {
        let area = imageSize.width * imageSize.height
        guard area > 0 else { return imageSize }

        let width = sqrt(area * targetRatio)
        let height = sqrt(area / targetRatio)
        return CGSize(width: width, height: height)
    }

    private static func estimatedOrientation(
        widthTop: Double,
        widthBottom: Double,
        heightLeft: Double,
        heightRight: Double
    ) -> DocumentOrientation? {
        let estimatedWidth = geometricMean(widthTop, widthBottom)
        let estimatedHeight = geometricMean(heightLeft, heightRight)
        guard estimatedWidth > 0.0, estimatedHeight > 0.0 else { return nil }
        return estimatedWidth > estimatedHeight ? .landscape : .portrait
    }

    private static func estimatedShortLongRatio(
        widthTop: Double,
        widthBottom: Double,
        heightLeft: Double,
        heightRight: Double
    ) -> Double {
        let estimatedWidth = geometricMean(widthTop, widthBottom)
        let estimatedHeight = geometricMean(heightLeft, heightRight)
        let shortSide = min(estimatedWidth, estimatedHeight)
        let longSide = max(estimatedWidth, estimatedHeight)
        return shortSide / max(0.0001, longSide)
    }

    private static func geometricMean(_ lhs: Double, _ rhs: Double) -> Double {
        sqrt(max(0.0001, lhs) * max(0.0001, rhs))
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> Double {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return sqrt(dx * dx + dy * dy)
    }

    private static func matchesAnchor(_ candidate: DetectedRectangle, _ anchor: DetectedRectangle?) -> Bool {
        guard let anchor else { return true }

        let candidatePoints = orderedPoints(candidate)
        let anchorPoints = orderedPoints(anchor)
        let distances = zip(candidatePoints, anchorPoints).map { distance($0.0, $0.1) }
        let meanDistance = distances.reduce(0.0, +) / Double(max(1, distances.count))
        let maxDistance = distances.max() ?? 0.0
        let centerDistance = distance(center(of: candidatePoints), center(of: anchorPoints))
        let candidateArea = polygonArea(candidatePoints)
        let anchorArea = polygonArea(anchorPoints)
        let areaRatio = min(candidateArea, anchorArea) / max(max(candidateArea, anchorArea), 0.0001)

        return meanDistance <= 0.16
            && maxDistance <= 0.28
            && centerDistance <= 0.17
            && areaRatio >= 0.50
    }

    private static func orderedPoints(_ rectangle: DetectedRectangle) -> [CGPoint] {
        [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
    }

    private static func center(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func polygonArea(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0.0 }
        var area = 0.0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += Double(current.x * next.y - current.y * next.x)
        }
        return abs(Double(area)) / 2.0
    }

    private static func configure(_ request: VNDetectRectanglesRequest) {
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.2
        request.minimumConfidence = 0.5
        request.maximumObservations = 8
    }

    private static func rectangle(
        from rect: VNRectangleObservation
    ) -> DetectedRectangle {
        return DetectedRectangle(
            topLeft: rect.topLeft,
            topRight: rect.topRight,
            bottomLeft: rect.bottomLeft,
            bottomRight: rect.bottomRight
        )
    }

    private static func rectangleFromVision(
        cgImage: CGImage,
        anchorRectangle: DetectedRectangle?
    ) -> VisionRectangleCandidate? {
        let request = VNDetectRectanglesRequest()
        configure(request)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])
        guard let results = request.results else {
            return nil
        }

        return bestVisionCandidate(from: results, anchorRectangle: anchorRectangle)
    }

    private static func bestVisionCandidate(
        from observations: [VNRectangleObservation],
        anchorRectangle: DetectedRectangle?
    ) -> VisionRectangleCandidate? {
        return observations
            .map { observation -> VisionRectangleCandidate in
                let detected = rectangle(from: observation)
                return VisionRectangleCandidate(
                    rectangle: detected,
                    confidence: observation.confidence,
                    score: scoreVisionRectangle(detected, confidence: observation.confidence)
                )
            }
            .filter { matchesAnchor($0.rectangle, anchorRectangle) }
            .max { $0.score < $1.score }
    }

    private static func rectangleFromOpenCV(in image: UIImage) -> DetectedRectangle? {
        guard let values = OpenCVDocumentFilterBridge.detectDocumentCorners(in: image),
            values.count == 4
        else {
            return nil
        }

        let points = values.map { $0.cgPointValue }
        return DetectedRectangle(
            topLeft: points[0],
            topRight: points[1],
            bottomLeft: points[3],
            bottomRight: points[2]
        )
    }

    private static func rectangleJson(_ rectangle: DetectedRectangle?) -> String {
        guard let rectangle else { return "{\"corners\":[]}" }
        let points = [
            rectangle.topLeft,
            rectangle.topRight,
            rectangle.bottomRight,
            rectangle.bottomLeft
        ]
        let pointJson = points.map { point in
            "{\"x\":\(point.x),\"y\":\(point.y)}"
        }.joined(separator: ",")
        return "{\"corners\":[\(pointJson)]}"
    }

    private static func scoreVisionRectangle(_ rectangle: DetectedRectangle, confidence: Float) -> Double {
        let points = orderedPoints(rectangle)
        let area = polygonArea(points)
        let centerDistance = distance(center(of: points), CGPoint(x: 0.5, y: 0.5))
        let centerScore = max(0.0, 1.0 - centerDistance / 0.50)
        let areaScore = min(1.0, area / 0.60)
        return Double(confidence) * 0.55 + centerScore * 0.30 + areaScore * 0.15
    }

    private static func drawRectangleOverlay(image: UIImage, rectangle: DetectedRectangle?) -> UIImage? {
        guard let rectangle else { return nil }
        let size = image.size
        let points = [
            uiPoint(fromVisionPoint: rectangle.topLeft, imageSize: size),
            uiPoint(fromVisionPoint: rectangle.topRight, imageSize: size),
            uiPoint(fromVisionPoint: rectangle.bottomRight, imageSize: size),
            uiPoint(fromVisionPoint: rectangle.bottomLeft, imageSize: size)
        ]

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            UIColor.systemBlue.setStroke()
            UIColor.systemBlue.setFill()
            let path = UIBezierPath()
            path.lineWidth = 4
            path.move(to: points[0])
            points.dropFirst().forEach { path.addLine(to: $0) }
            path.close()
            path.stroke()

            for point in points {
                context.cgContext.fillEllipse(in: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12))
            }
        }
    }

    private static func uiPoint(fromVisionPoint point: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * imageSize.width, y: (1 - point.y) * imageSize.height)
    }
}
