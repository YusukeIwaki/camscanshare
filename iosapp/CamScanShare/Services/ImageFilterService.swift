import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ImageFilterService {
    enum RenderIntent {
        case preview
        case export
    }

    private static let displayContext = CIContext()

    static func applyFilter(
        _ preset: FilterPreset,
        to image: UIImage,
        rotation: Int = 0,
        intent: RenderIntent = .preview,
        previewMaxDimension: CGFloat = 1800
    ) -> UIImage? {
        let debugSink = ImageProcessingDebugSink.shared
        let session = debugSink.startSession(
            category: "filter",
            label: preset.rawValue,
            metadata: [
                "filterKey": preset.rawValue,
                "intent": intent == .preview ? "preview" : "export",
                "inputWidth": "\(Int(image.size.width))",
                "inputHeight": "\(Int(image.size.height))",
                "rotationDegrees": "\(rotation)"
            ]
        )
        let startedAt = debugSink.now()
        debugSink.writeImage(session, label: "input", image: image)
        let normalizedRotation = ((rotation % 360) + 360) % 360

        let output: UIImage?
        if usesOpenCVPipeline(for: preset) {
            if intent == .preview {
                output = OpenCVDocumentFilterBridge.applyPreviewFilterNamed(
                    preset.rawValue,
                    to: image,
                    rotationDegrees: normalizedRotation,
                    maxDimension: previewMaxDimension
                )
            } else {
                output = OpenCVDocumentFilterBridge.applyFilterNamed(
                    preset.rawValue,
                    to: image,
                    rotationDegrees: normalizedRotation
                )
            }
        } else {
            output = applyCoreImageFilter(
                preset,
                to: image,
                normalizedRotation: normalizedRotation,
                intent: intent,
                previewMaxDimension: previewMaxDimension
            )
        }

        debugSink.writeImage(session, label: "output", image: output)
        debugSink.recordTimingSince(
            session,
            stage: "filter.total",
            startedAt: startedAt,
            metadata: [
                "outputWidth": output.map { "\(Int($0.size.width))" } ?? "none",
                "outputHeight": output.map { "\(Int($0.size.height))" } ?? "none"
            ]
        )
        return output
    }

    private static func applyCoreImageFilter(
        _ preset: FilterPreset,
        to image: UIImage,
        normalizedRotation: Int,
        intent: RenderIntent,
        previewMaxDimension: CGFloat
    ) -> UIImage? {
        guard var ciImage = CIImage(image: image) else { return nil }

        if normalizedRotation != 0 {
            let radians = -Double(normalizedRotation) * .pi / 180.0
            ciImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
            let translatedOrigin = ciImage.extent.origin
            ciImage = ciImage.transformed(
                by: CGAffineTransform(translationX: -translatedOrigin.x, y: -translatedOrigin.y)
            )
        }

        ciImage = downscaleIfNeeded(ciImage, maxDimension: previewMaxDimension, intent: intent)
        ciImage = applySimpleFilter(preset, to: ciImage)

        guard let cgImage = displayContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    private static func applySimpleFilter(_ preset: FilterPreset, to image: CIImage) -> CIImage {
        switch preset {
        case .original:
            return image

        case .sharpen:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = 1.4
            filter.brightness = 0.05
            return filter.outputImage ?? image

        case .vivid:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = 2.0
            filter.contrast = 1.2
            return filter.outputImage ?? image

        case .enhance, .eco, .shadowless, .bw, .magic, .magicPro, .whiteboard:
            assertionFailure("Document filters must be handled by OpenCV")
            return image
        }
    }

    private static func downscaleIfNeeded(
        _ image: CIImage,
        maxDimension: CGFloat,
        intent: RenderIntent
    ) -> CIImage {
        guard intent == .preview else { return image }
        let maxSide = max(image.extent.width, image.extent.height)
        guard maxSide > maxDimension, maxSide > 0 else { return image }

        let scale = maxDimension / maxSide
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? image
    }

    private static func usesOpenCVPipeline(for preset: FilterPreset) -> Bool {
        switch preset {
        case .enhance, .eco, .shadowless, .bw, .magic, .magicPro, .whiteboard:
            true
        case .original, .sharpen, .vivid:
            false
        }
    }
}
