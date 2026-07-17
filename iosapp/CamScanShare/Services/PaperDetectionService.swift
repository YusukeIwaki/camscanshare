import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct DetectedRectangle: Sendable, Equatable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomLeft: CGPoint
    let bottomRight: CGPoint
}

enum DocumentOrientation {
    case portrait
    case landscape
}

enum PaperDetectionService {
    private static let a4Portrait = 210.0 / 297.0
    private static let a4Landscape = 297.0 / 210.0
    private static let a4Tolerance = 0.20

    static func recordFinderFrame(
        image: UIImage,
        rawRectangle: DetectedRectangle?,
        displayedRectangle: DetectedRectangle?,
        debugSink: ImageProcessingDebugSink
    ) {
        let session = debugSink.startSession(
            category: "paper-detection",
            label: "finder",
            metadata: [
                "inputWidth": "\(Int(image.size.width))",
                "inputHeight": "\(Int(image.size.height))",
                "platform": "ios",
                "mode": "preview",
                "coordinateOrigin": "bottom_left",
                "selectionSource": "stabilized_preview"
            ]
        )
        let startedAt = debugSink.now()
        let selectedRectangle = displayedRectangle ?? rawRectangle
        debugSink.writeImage(session, label: "input", image: image)
        debugSink.writeText(session, fileName: "raw_quad.json", text: rectangleJson(rawRectangle))
        debugSink.writeText(
            session,
            fileName: "selected_quad.json",
            text: rectangleJson(selectedRectangle)
        )
        debugSink.writeImage(
            session,
            label: "selected_quad_overlay",
            image: drawRectangleOverlay(image: image, rectangle: selectedRectangle)
        )
        debugSink.recordTimingSince(
            session,
            stage: "paper_detection.finder_snapshot",
            startedAt: startedAt,
            metadata: ["result": selectedRectangle == nil ? "none" : "quad"]
        )
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

        let openCVRectangle = rectangleFromOpenCV(in: uprightImage, anchorRectangle: anchorRectangle)
        let rectangle: DetectedRectangle?
        let source: String
        if let openCVRectangle {
            rectangle = openCVRectangle
            source = "opencv"
        } else if let anchorRectangle {
            rectangle = anchorRectangle
            source = "preview_anchor"
        } else {
            rectangle = nil
            source = "none"
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

        // Convert normalized bottom-left-origin coordinates to CIImage coordinates.
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

    private static func orderedPoints(_ rectangle: DetectedRectangle) -> [CGPoint] {
        [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft]
    }

    static func detectPreviewRectangle(in image: UIImage) -> DetectedRectangle? {
        rectangle(from: OpenCVDocumentFilterBridge.detectPreviewDocumentCorners(in: image))
    }

    private static func rectangleFromOpenCV(
        in image: UIImage,
        anchorRectangle: DetectedRectangle?
    ) -> DetectedRectangle? {
        let values: [NSValue]?
        if let anchorRectangle {
            let anchorValues = orderedPoints(anchorRectangle).map { NSValue(cgPoint: $0) }
            values = OpenCVDocumentFilterBridge.detectDocumentCorners(in: image, anchorCorners: anchorValues)
        } else {
            values = OpenCVDocumentFilterBridge.detectDocumentCorners(in: image)
        }
        return rectangle(from: values)
    }

    private static func rectangle(from values: [NSValue]?) -> DetectedRectangle? {
        guard let values, values.count == 4 else { return nil }
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

    private static func drawRectangleOverlay(image: UIImage, rectangle: DetectedRectangle?) -> UIImage? {
        guard let rectangle else { return nil }
        let size = image.size
        let points = [
            uiPoint(fromNormalizedPoint: rectangle.topLeft, imageSize: size),
            uiPoint(fromNormalizedPoint: rectangle.topRight, imageSize: size),
            uiPoint(fromNormalizedPoint: rectangle.bottomRight, imageSize: size),
            uiPoint(fromNormalizedPoint: rectangle.bottomLeft, imageSize: size)
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

    private static func uiPoint(fromNormalizedPoint point: CGPoint, imageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x * imageSize.width, y: (1 - point.y) * imageSize.height)
    }
}
