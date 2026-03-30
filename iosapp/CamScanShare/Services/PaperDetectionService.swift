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
            completion(rectangle(from: request, error: error))
        }
        configure(request)
        return request
    }

    static func detectRectangle(in image: UIImage) -> DetectedRectangle? {
        let uprightImage = image.normalizedOrientation()
        guard let cgImage = uprightImage.cgImage else { return nil }

        let request = VNDetectRectanglesRequest()
        configure(request)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        try? handler.perform([request])
        return rectangle(from: request, error: nil)
    }

    static func correctDocumentGeometry(image: UIImage) -> UIImage {
        let uprightImage = image.normalizedOrientation()
        guard let rectangle = detectRectangle(in: uprightImage),
            let step0 = correctPerspective(image: uprightImage, rectangle: rectangle)
        else {
            return uprightImage
        }
        return normalizeDocumentAspect(step0, rectangle: rectangle)
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

    private static func configure(_ request: VNDetectRectanglesRequest) {
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.2
        request.minimumConfidence = 0.5
        request.maximumObservations = 1
    }

    private static func rectangle(
        from request: VNRequest,
        error: Error?
    ) -> DetectedRectangle? {
        guard error == nil,
            let results = request.results as? [VNRectangleObservation],
            let rect = results.first
        else {
            return nil
        }
        return DetectedRectangle(
            topLeft: rect.topLeft,
            topRight: rect.topRight,
            bottomLeft: rect.bottomLeft,
            bottomRight: rect.bottomRight
        )
    }
}
