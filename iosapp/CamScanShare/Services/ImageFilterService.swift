import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ImageFilterService {
    private static let context = CIContext()

    static func applyFilter(_ preset: FilterPreset, to image: UIImage, rotation: Int = 0) -> UIImage? {
        guard var ciImage = CIImage(image: image) else { return nil }

        // Apply rotation
        let normalizedRotation = ((rotation % 360) + 360) % 360
        if normalizedRotation != 0 {
            let radians = -Double(normalizedRotation) * .pi / 180.0
            ciImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
            // Translate to keep origin at (0,0)
            let translatedOrigin = ciImage.extent.origin
            ciImage = ciImage.transformed(
                by: CGAffineTransform(translationX: -translatedOrigin.x, y: -translatedOrigin.y))
        }

        // Apply filter
        ciImage = applyFilterChain(preset, to: ciImage)

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func applyFilterChain(_ preset: FilterPreset, to image: CIImage) -> CIImage {
        switch preset {
        case .original:
            return image

        case .sharpen:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = 1.4
            filter.brightness = 0.05
            return filter.outputImage ?? image

        case .bw:
            let mono = CIFilter.colorMonochrome()
            mono.inputImage = image
            mono.color = CIColor(red: 0.7, green: 0.7, blue: 0.7)
            mono.intensity = 1.0
            let monoOutput = mono.outputImage ?? image

            let contrast = CIFilter.colorControls()
            contrast.inputImage = monoOutput
            contrast.contrast = 1.3
            return contrast.outputImage ?? monoOutput

        case .magic:
            // Flat-field correction: divide original by blurred version to remove uneven lighting
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = image
            blur.radius = Float(min(image.extent.width, image.extent.height) * 0.05)
            guard let blurred = blur.outputImage else { return image }

            let divide = CIFilter.divideBlendMode()
            divide.inputImage = image
            divide.backgroundImage = blurred
            guard let divided = divide.outputImage else { return image }

            let contrast = CIFilter.colorControls()
            contrast.inputImage = divided.cropped(to: image.extent)
            contrast.contrast = 1.5
            contrast.brightness = 0.05
            contrast.saturation = 0.3
            return contrast.outputImage ?? image

        case .whiteboard:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = 0.3
            filter.contrast = 1.6
            filter.saturation = 0.0
            return filter.outputImage ?? image

        case .vivid:
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = 2.0
            filter.contrast = 1.2
            return filter.outputImage ?? image
        }
    }
}
