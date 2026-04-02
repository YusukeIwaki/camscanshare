import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum ImageFilterService {
    enum RenderIntent {
        case preview
        case export
    }

    private struct LabPlanes {
        let width: Int
        let height: Int
        let l: [UInt8]
        let a: [UInt8]
        let b: [UInt8]
    }

    private static let displayContext = CIContext()
    private static let rawContext = CIContext(
        options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ])

    static func applyFilter(
        _ preset: FilterPreset,
        to image: UIImage,
        rotation: Int = 0,
        intent: RenderIntent = .preview,
        previewMaxDimension: CGFloat = 1800
    ) -> UIImage? {
        let normalizedRotation = ((rotation % 360) + 360) % 360
        if intent == .preview,
            shouldUseOpenCVPreviewPipeline(for: preset),
            let renderedPreview = OpenCVDocumentFilterBridge.applyPreviewFilterNamed(
                preset.rawValue,
                to: image,
                rotationDegrees: normalizedRotation,
                maxDimension: previewMaxDimension
            )
        {
            return renderedPreview
        }

        guard var ciImage = CIImage(image: image) else { return nil }

        if normalizedRotation != 0 {
            let radians = -Double(normalizedRotation) * .pi / 180.0
            ciImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
            let translatedOrigin = ciImage.extent.origin
            ciImage = ciImage.transformed(
                by: CGAffineTransform(translationX: -translatedOrigin.x, y: -translatedOrigin.y))
        }

        ciImage = applyFilterChain(
            preset,
            to: ciImage,
            intent: intent,
            previewMaxDimension: previewMaxDimension
        )

        guard let cgImage = displayContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    private static func applyFilterChain(
        _ preset: FilterPreset,
        to image: CIImage,
        intent: RenderIntent,
        previewMaxDimension: CGFloat
    ) -> CIImage {
        let workingImage = downscaleIfNeeded(image, maxDimension: previewMaxDimension, intent: intent)

        switch preset {
        case .original:
            return workingImage

        case .sharpen:
            let filter = CIFilter.colorControls()
            filter.inputImage = workingImage
            filter.contrast = 1.4
            filter.brightness = 0.05
            return filter.outputImage ?? workingImage

        case .bw:
            return applyDocumentBWPipeline(to: workingImage) ?? workingImage

        case .magic:
            return applyMagicPipeline(to: workingImage) ?? workingImage

        case .whiteboard:
            return applyWhiteboardPipeline(to: workingImage) ?? workingImage

        case .vivid:
            let filter = CIFilter.colorControls()
            filter.inputImage = workingImage
            filter.saturation = 2.0
            filter.contrast = 1.2
            return filter.outputImage ?? workingImage
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

    private static func shouldUseOpenCVPreviewPipeline(for preset: FilterPreset) -> Bool {
        switch preset {
        case .bw, .magic, .whiteboard:
            true
        case .original, .sharpen, .vivid:
            false
        }
    }

    private static func applyDocumentBWPipeline(to image: CIImage) -> CIImage? {
        let originalWidth = Int(round(image.extent.width))
        let originalHeight = Int(round(image.extent.height))
        guard originalWidth > 0, originalHeight > 0 else { return nil }

        let shouldUpscale = max(originalWidth, originalHeight) < 1400
        let workingImage: CIImage
        if shouldUpscale {
            guard let scaled = scaleImage(image, scale: 2.0) else { return nil }
            workingImage = scaled
        } else {
            workingImage = image
        }

        guard let lab = extractLabPlanes(from: workingImage) else { return nil }
        let luminance = lab.l
        let illumination = estimateIllumination(luminance, width: lab.width, height: lab.height)
        let flattenedL = flatFieldCorrect(luminance, illumination: illumination)
        let stretchedL = autoStretchLuminance(flattenedL)
        let denoisedL = medianBlur3(stretchedL, width: lab.width, height: lab.height)
        let emphasizedL = applyChannelContrast(denoisedL, value: 1.48)

        var paperMask = buildPaperMask(
            luminance: denoisedL,
            aChannel: lab.a,
            bChannel: lab.b,
            width: lab.width,
            height: lab.height
        )

        let (softStructureRaw, strongStructureRaw) = buildSauvolaStructureMasks(
            luminance: emphasizedL,
            width: lab.width,
            height: lab.height
        )
        let darkThreshold = max(70, percentile(denoisedL, percentile: 0.12))
        let darkMask = thresholdMask(denoisedL, threshold: darkThreshold, inverse: true)
        var strongStructure = bitwiseOr(strongStructureRaw, darkMask)
        let softStructure = dilateMask(softStructureRaw, radius: 1, iterations: 1, width: lab.width, height: lab.height)
        strongStructure = dilateMask(strongStructure, radius: 1, iterations: 1, width: lab.width, height: lab.height)
        var structureMask = bitwiseOr(softStructure, strongStructure)
        structureMask = medianBlur3(structureMask, width: lab.width, height: lab.height)

        paperMask = bitwiseAnd(paperMask, bitwiseNot(structureMask))
        paperMask = morphologyClose(paperMask, radius: 2, iterations: 2, width: lab.width, height: lab.height)

        var tonedL = blendTowardValue(emphasizedL, mask: paperMask, target: 246.0, strength: 0.44)
        for index in tonedL.indices where structureMask[index] > 0 {
            tonedL[index] = clampToUInt8(min(Float(tonedL[index]), Float(emphasizedL[index]) * 0.92))
        }

        var brightBackground = thresholdMask(tonedL, threshold: 182, inverse: false)
        brightBackground = bitwiseAnd(brightBackground, bitwiseNot(structureMask))
        tonedL = blendTowardValue(tonedL, mask: brightBackground, target: 236.0, strength: 0.32)

        let quantizeSource = gaussianBlur(tonedL, sigma: 0.8, width: lab.width, height: lab.height)
        let toneCount = estimateBWToneCount(quantizeSource)
        let levels = fitQuantizationLevels(quantizeSource, toneCount: toneCount)
        var quantized = quantizeWithLevels(quantizeSource, levels: levels)

        if toneCount >= 3, levels.count >= 2 {
            let paperFloor = levels[levels.count - 2]
            for index in quantized.indices where paperMask[index] > 0 {
                quantized[index] = max(quantized[index], UInt8(paperFloor))
            }
        } else if let whiteLevel = levels.last {
            for index in quantized.indices where paperMask[index] > 0 {
                quantized[index] = UInt8(whiteLevel)
            }
        }

        var outputImage = makeRGBImage(
            red: quantized,
            green: quantized,
            blue: quantized,
            width: lab.width,
            height: lab.height
        )

        if shouldUpscale {
            let scale = CGFloat(originalWidth) / CGFloat(lab.width)
            outputImage = scaleImage(outputImage, scale: scale) ?? outputImage
        }

        return outputImage
    }

    private static func applyMagicPipeline(to image: CIImage) -> CIImage? {
        guard let lab = extractLabPlanes(from: image) else { return nil }

        let luminance = lab.l
        let illumination = estimateIllumination(luminance, width: lab.width, height: lab.height)
        let flattenedL = flatFieldCorrect(luminance, illumination: illumination)
        let stretchedL = autoStretchLuminance(flattenedL)
        let denoisedL = medianBlur3(stretchedL, width: lab.width, height: lab.height)

        var paperMask = buildPaperMask(
            luminance: denoisedL,
            aChannel: lab.a,
            bChannel: lab.b,
            width: lab.width,
            height: lab.height
        )
        let structureMask = buildStructureMask(denoisedL, width: lab.width, height: lab.height)
        paperMask = bitwiseAnd(paperMask, bitwiseNot(structureMask))
        paperMask = morphologyClose(paperMask, radius: 2, iterations: 2, width: lab.width, height: lab.height)

        let accentMask = buildAccentMask(
            luminance: denoisedL,
            aChannel: lab.a,
            bChannel: lab.b,
            width: lab.width,
            height: lab.height
        )

        let meanA = meanMaskedValue(lab.a, mask: paperMask) ?? 128.0
        let meanB = meanMaskedValue(lab.b, mask: paperMask) ?? 128.0
        let neutralizedA = neutralizeColorChannel(lab.a, paperMean: meanA)
        let neutralizedB = neutralizeColorChannel(lab.b, paperMean: meanB)

        guard let neutralReferenceImage = makeCIImageFromLab(
            l: denoisedL,
            a: neutralizedA,
            b: neutralizedB,
            width: lab.width,
            height: lab.height
        ) else { return nil }
        let neutralReferenceRGB = extractRGBPlanes(from: neutralReferenceImage)
        let referenceSaturation = computeSaturation(
            red: neutralReferenceRGB.red,
            green: neutralReferenceRGB.green,
            blue: neutralReferenceRGB.blue
        )
        let visibleMask = thresholdMask(denoisedL, threshold: 48, inverse: false)
        let colorRichness = estimateColorRichness(referenceSaturation, visibleMask: visibleMask)
        let paperColorMask = buildPaperColorMask(
            referenceSaturation: referenceSaturation,
            luminance: denoisedL,
            paperMask: paperMask,
            accentMask: accentMask,
            colorRichness: colorRichness,
            width: lab.width,
            height: lab.height
        )

        let mutedFactor = Float(0.18 + 0.18 * colorRichness)
        let paperColorFactor = Float(0.42 + 0.30 * colorRichness)
        let accentFactor = Float(min(1.0, 0.86 + 0.10 * colorRichness))
        let mutedA = compressChroma(neutralizedA, factor: mutedFactor)
        let mutedB = compressChroma(neutralizedB, factor: mutedFactor)
        let paperColorA = compressChroma(neutralizedA, factor: paperColorFactor)
        let paperColorB = compressChroma(neutralizedB, factor: paperColorFactor)
        let accentA = compressChroma(neutralizedA, factor: accentFactor)
        let accentB = compressChroma(neutralizedB, factor: accentFactor)

        var outputL = blendTowardValue(denoisedL, mask: paperMask, target: 244.0, strength: 0.34)
        outputL = weightedBlend(outputL, denoisedL, weightA: 0.58, weightB: 0.42)
        outputL = blendMaskedTowardReference(
            outputL,
            reference: denoisedL,
            mask: paperColorMask,
            referenceWeight: Float(0.24 + 0.18 * colorRichness)
        )

        var outputA = mutedA
        var outputB = mutedB
        for index in outputA.indices where paperColorMask[index] > 0 {
            outputA[index] = paperColorA[index]
            outputB[index] = paperColorB[index]
        }
        for index in outputA.indices where accentMask[index] > 0 {
            outputA[index] = accentA[index]
            outputB[index] = accentB[index]
        }

        let paperNeutralizeMask = bitwiseAnd(
            bitwiseAnd(paperMask, bitwiseNot(paperColorMask)),
            bitwiseNot(accentMask)
        )
        for index in outputA.indices where paperNeutralizeMask[index] > 0 {
            outputA[index] = 128
            outputB[index] = 128
        }

        guard let finalLabImage = makeCIImageFromLab(
            l: outputL,
            a: outputA,
            b: outputB,
            width: lab.width,
            height: lab.height
        ) else { return nil }

        let finalRGB = extractRGBPlanes(from: finalLabImage)
        let restoredRGB = restoreContentSaturation(
            red: finalRGB.red,
            green: finalRGB.green,
            blue: finalRGB.blue,
            referenceRed: neutralReferenceRGB.red,
            referenceGreen: neutralReferenceRGB.green,
            referenceBlue: neutralReferenceRGB.blue,
            luminance: denoisedL,
            paperMask: paperMask,
            accentMask: accentMask,
            paperColorMask: paperColorMask
        )

        return makeRGBImage(
            red: restoredRGB.red,
            green: restoredRGB.green,
            blue: restoredRGB.blue,
            width: lab.width,
            height: lab.height
        )
    }

    private static func applyWhiteboardPipeline(to image: CIImage) -> CIImage? {
        guard let lab = extractLabPlanes(from: image) else { return nil }

        let luminance = lab.l
        let illumination = estimateIllumination(luminance, width: lab.width, height: lab.height)
        let flattenedL = flatFieldCorrect(luminance, illumination: illumination)
        let stretchedL = autoStretchLuminance(flattenedL)
        let denoisedL = medianBlur3(stretchedL, width: lab.width, height: lab.height)

        let chroma = computeChroma(aChannel: lab.a, bChannel: lab.b)
        var accentMask = buildAccentMask(
            luminance: denoisedL,
            aChannel: lab.a,
            bChannel: lab.b,
            width: lab.width,
            height: lab.height
        )
        let mediumChromaMask = thresholdMask(chroma, threshold: 18, inverse: false)
        let visibleMask = thresholdMask(denoisedL, threshold: 42, inverse: false)
        accentMask = bitwiseOr(accentMask, bitwiseAnd(mediumChromaMask, visibleMask))
        accentMask = morphologyOpen(accentMask, radius: 1, iterations: 1, width: lab.width, height: lab.height)

        let accentProtectMask = dilateMask(accentMask, radius: 1, iterations: 1, width: lab.width, height: lab.height)

        var structureMask = buildStructureMask(denoisedL, width: lab.width, height: lab.height)
        let (_, sauvolaStrong) = buildSauvolaStructureMasks(
            luminance: applyChannelContrast(denoisedL, value: 1.22),
            width: lab.width,
            height: lab.height,
            windowSize: 35,
            k: 0.16,
            dynamicRange: 128.0
        )
        structureMask = bitwiseOr(structureMask, sauvolaStrong)
        structureMask = bitwiseOr(structureMask, accentProtectMask)
        structureMask = medianBlur3(structureMask, width: lab.width, height: lab.height)
        structureMask = dilateMask(structureMask, radius: 1, iterations: 1, width: lab.width, height: lab.height)

        var paperMask = buildPaperMask(
            luminance: denoisedL,
            aChannel: lab.a,
            bChannel: lab.b,
            width: lab.width,
            height: lab.height
        )
        let brightThreshold = max(156, percentile(denoisedL, percentile: 0.58))
        let brightMask = thresholdMask(denoisedL, threshold: brightThreshold, inverse: false)
        paperMask = bitwiseOr(paperMask, brightMask)
        paperMask = bitwiseAnd(paperMask, bitwiseNot(structureMask))
        paperMask = bitwiseAnd(paperMask, bitwiseNot(accentProtectMask))
        paperMask = morphologyClose(paperMask, radius: 2, iterations: 2, width: lab.width, height: lab.height)

        let meanA = meanMaskedValue(lab.a, mask: paperMask) ?? 128.0
        let meanB = meanMaskedValue(lab.b, mask: paperMask) ?? 128.0

        let neutralizedA = neutralizeColorChannel(lab.a, paperMean: meanA)
        let neutralizedB = neutralizeColorChannel(lab.b, paperMean: meanB)

        let mutedA = compressChroma(neutralizedA, factor: 0.42)
        let mutedB = compressChroma(neutralizedB, factor: 0.42)
        let accentA = compressChroma(neutralizedA, factor: 1.32)
        let accentB = compressChroma(neutralizedB, factor: 1.32)

        var outputL = blendTowardValue(denoisedL, mask: paperMask, target: 250.0, strength: 0.50)
        outputL = weightedBlend(outputL, denoisedL, weightA: 0.68, weightB: 0.32)

        for index in outputL.indices where sauvolaStrong[index] > 0 {
            outputL[index] = clampToUInt8(min(Float(outputL[index]), Float(denoisedL[index]) * 0.84))
        }
        for index in outputL.indices where accentProtectMask[index] > 0 {
            outputL[index] = clampToUInt8(min(Float(outputL[index]), Float(denoisedL[index]) * 0.92))
        }

        var outputA = mutedA
        var outputB = mutedB
        for index in outputA.indices where accentMask[index] > 0 {
            outputA[index] = accentA[index]
            outputB[index] = accentB[index]
        }
        for index in outputA.indices where paperMask[index] > 0 {
            outputA[index] = 128
            outputB[index] = 128
        }

        guard var finalImage = makeCIImageFromLab(
            l: outputL,
            a: outputA,
            b: outputB,
            width: lab.width,
            height: lab.height
        ) else { return nil }

        var rgb = extractRGBPlanes(from: finalImage)
        guard rgb.width == lab.width, rgb.height == lab.height else { return nil }

        for index in accentMask.indices where accentMask[index] > 0 {
            var (hue, saturation, value) = rgbToHSV(
                red: rgb.red[index],
                green: rgb.green[index],
                blue: rgb.blue[index]
            )
            saturation = min(1.0, saturation * 1.38 + (8.0 / 255.0))
            value = min(1.0, value * 1.05 + (2.0 / 255.0))
            let (red, green, blue) = hsvToRGB(hue: hue, saturation: saturation, value: value)
            rgb.red[index] = red
            rgb.green[index] = green
            rgb.blue[index] = blue
        }

        finalImage = makeRGBImage(
            red: rgb.red,
            green: rgb.green,
            blue: rgb.blue,
            width: rgb.width,
            height: rgb.height
        )
        return finalImage
    }

    private static func extractLabPlanes(from image: CIImage) -> LabPlanes? {
        let extent = image.extent.integral
        let translated = image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        let labImage = translated.convertingWorkingSpaceToLab()
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return nil }

        var pixels = [Float](repeating: 0, count: width * height * 4)
        rawContext.render(
            labImage,
            toBitmap: &pixels,
            rowBytes: width * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )

        var l = [UInt8](repeating: 0, count: width * height)
        var a = [UInt8](repeating: 0, count: width * height)
        var b = [UInt8](repeating: 0, count: width * height)

        for index in 0..<(width * height) {
            let base = index * 4
            l[index] = clampToUInt8((pixels[base] * 255.0) / 100.0)
            a[index] = clampToUInt8(pixels[base + 1] + 128.0)
            b[index] = clampToUInt8(pixels[base + 2] + 128.0)
        }

        return LabPlanes(width: width, height: height, l: l, a: a, b: b)
    }

    private static func makeCIImageFromLab(
        l: [UInt8],
        a: [UInt8],
        b: [UInt8],
        width: Int,
        height: Int
    ) -> CIImage? {
        guard l.count == width * height, a.count == width * height, b.count == width * height else { return nil }
        var pixels = [Float](repeating: 0, count: width * height * 4)

        for index in 0..<(width * height) {
            let base = index * 4
            pixels[base] = Float(l[index]) * 100.0 / 255.0
            pixels[base + 1] = Float(a[index]) - 128.0
            pixels[base + 2] = Float(b[index]) - 128.0
            pixels[base + 3] = 1.0
        }

        let data = Data(bytes: pixels, count: pixels.count * MemoryLayout<Float>.size)
        let labImage = CIImage(
            bitmapData: data,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: width, height: height),
            format: .RGBAf,
            colorSpace: nil
        )
        return labImage.convertingLabToWorkingSpace()
    }

    private static func extractRGBPlanes(from image: CIImage) -> (red: [UInt8], green: [UInt8], blue: [UInt8], width: Int, height: Int) {
        let extent = image.extent.integral
        let translated = image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )
        let width = Int(extent.width)
        let height = Int(extent.height)
        var packed = [UInt8](repeating: 0, count: width * height * 4)

        rawContext.render(
            translated,
            toBitmap: &packed,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: nil
        )

        var red = [UInt8](repeating: 0, count: width * height)
        var green = [UInt8](repeating: 0, count: width * height)
        var blue = [UInt8](repeating: 0, count: width * height)

        for index in 0..<(width * height) {
            let base = index * 4
            red[index] = packed[base]
            green[index] = packed[base + 1]
            blue[index] = packed[base + 2]
        }

        return (red, green, blue, width, height)
    }

    private static func makeRGBImage(
        red: [UInt8],
        green: [UInt8],
        blue: [UInt8],
        width: Int,
        height: Int
    ) -> CIImage {
        var packed = [UInt8](repeating: 255, count: width * height * 4)

        for index in 0..<(width * height) {
            let base = index * 4
            packed[base] = red[index]
            packed[base + 1] = green[index]
            packed[base + 2] = blue[index]
        }

        let data = Data(packed)
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: nil
        )
    }

    private static func scaleImage(_ image: CIImage, scale: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage
    }

    private static func estimateIllumination(_ luminance: [UInt8], width: Int, height: Int) -> [UInt8] {
        let minSide = min(width, height)
        let scale = minSide > 1024 ? (1024.0 / CGFloat(minSide)) : 1.0

        let workingWidth: Int
        let workingHeight: Int
        let workingLuminance: [UInt8]

        if scale < 1.0 {
            let image = makeGrayscaleImage(luminance, width: width, height: height)
            let scaled = scaleImage(image, scale: scale) ?? image
            workingWidth = Int(round(scaled.extent.width))
            workingHeight = Int(round(scaled.extent.height))
            workingLuminance = renderGrayscalePixels(scaled, width: workingWidth, height: workingHeight)
        } else {
            workingWidth = width
            workingHeight = height
            workingLuminance = luminance
        }

        var kernelSide = max(15, Int(round(Double(min(workingWidth, workingHeight)) / 24.0)))
        if kernelSide.isMultiple(of: 2) {
            kernelSide += 1
        }
        let radius = kernelSide / 2
        let closed = morphologyClose(
            workingLuminance,
            radius: radius,
            iterations: 1,
            width: workingWidth,
            height: workingHeight
        )
        let sigma = max(12.0, min(80.0, CGFloat(min(workingWidth, workingHeight)) / 18.0))
        let blurred = gaussianBlur(closed, sigma: Float(sigma), width: workingWidth, height: workingHeight)

        guard scale < 1.0 else { return blurred }
        let image = makeGrayscaleImage(blurred, width: workingWidth, height: workingHeight)
        let restored = scaleImage(image, scale: 1.0 / scale) ?? image
        return renderGrayscalePixels(restored, width: width, height: height)
    }

    private static func flatFieldCorrect(_ luminance: [UInt8], illumination: [UInt8]) -> [UInt8] {
        let illuminationMean = max(1.0, meanValue(illumination))
        return zip(luminance, illumination).map { luminanceValue, illuminationValue in
            let corrected = ((Float(luminanceValue) + 1.0) / (Float(illuminationValue) + 1.0)) * illuminationMean
            return clampToUInt8(corrected)
        }
    }

    private static func autoStretchLuminance(_ luminance: [UInt8]) -> [UInt8] {
        let histogram = histogram(for: luminance)
        let totalPixels = luminance.count
        let blackPoint = percentile(from: histogram, totalPixels: totalPixels, percentile: 0.005)
        let whitePoint = max(blackPoint + 1, percentile(from: histogram, totalPixels: totalPixels, percentile: 0.995))

        return luminance.map { value in
            let clipped = min(Int(value), whitePoint)
            let stretched = (Float(clipped - blackPoint) * 255.0) / Float(whitePoint - blackPoint)
            return clampToUInt8(stretched)
        }
    }

    private static func buildPaperMask(
        luminance: [UInt8],
        aChannel: [UInt8],
        bChannel: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        let chroma = computeChroma(aChannel: aChannel, bChannel: bChannel)
        let brightThreshold = max(96, percentile(luminance, percentile: 0.18))
        let brightMask = thresholdMask(luminance, threshold: brightThreshold, inverse: false)
        let lowChromaMask = thresholdMask(chroma, threshold: 34, inverse: true)
        var paperMask = bitwiseAnd(brightMask, lowChromaMask)
        paperMask = morphologyClose(paperMask, radius: 2, iterations: 2, width: width, height: height)
        paperMask = morphologyOpen(paperMask, radius: 2, iterations: 1, width: width, height: height)
        return paperMask
    }

    private static func buildAccentMask(
        luminance: [UInt8],
        aChannel: [UInt8],
        bChannel: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        let chroma = computeChroma(aChannel: aChannel, bChannel: bChannel)
        let strongChromaMask = thresholdMask(chroma, threshold: 28, inverse: false)
        let visibleMask = thresholdMask(luminance, threshold: 48, inverse: false)
        let accentMask = bitwiseAnd(strongChromaMask, visibleMask)
        return morphologyOpen(accentMask, radius: 1, iterations: 1, width: width, height: height)
    }

    private static func buildStructureMask(_ luminance: [UInt8], width: Int, height: Int) -> [UInt8] {
        let adaptiveReference = gaussianBlur(luminance, sigma: 5.0, width: width, height: height)
        var adaptive = [UInt8](repeating: 0, count: luminance.count)
        for index in luminance.indices {
            let threshold = max(0, Int(adaptiveReference[index]) - 9)
            adaptive[index] = luminance[index] <= UInt8(threshold) ? 255 : 0
        }

        let darkThreshold = max(72, percentile(luminance, percentile: 0.10))
        let dark = thresholdMask(luminance, threshold: darkThreshold, inverse: true)
        var structure = bitwiseOr(adaptive, dark)
        structure = morphologyOpen(structure, radius: 1, iterations: 1, width: width, height: height)
        structure = dilateMask(structure, radius: 1, iterations: 2, width: width, height: height)
        return structure
    }

    private static func buildSauvolaStructureMasks(
        luminance: [UInt8],
        width: Int,
        height: Int,
        windowSize: Int = 31,
        k: Float = 0.18,
        dynamicRange: Float = 128.0
    ) -> (soft: [UInt8], strong: [UInt8]) {
        let radius = windowSize / 2
        let area = Float(windowSize * windowSize)
        var soft = [UInt8](repeating: 0, count: luminance.count)
        var strong = [UInt8](repeating: 0, count: luminance.count)

        struct RowData {
            let sums: [Float]
            let squaredSums: [Float]
        }

        func horizontalSums(for row: Int) -> RowData {
            let rowIndex = max(0, min(height - 1, row))
            let base = rowIndex * width
            var sums = [Float](repeating: 0, count: width)
            var squaredSums = [Float](repeating: 0, count: width)

            var runningSum: Float = 0
            var runningSquaredSum: Float = 0
            for offset in -radius...radius {
                let column = max(0, min(width - 1, offset))
                let value = Float(luminance[base + column])
                runningSum += value
                runningSquaredSum += value * value
            }
            sums[0] = runningSum
            squaredSums[0] = runningSquaredSum

            guard width > 1 else { return RowData(sums: sums, squaredSums: squaredSums) }

            for x in 1..<width {
                let removeColumn = max(0, min(width - 1, x - radius - 1))
                let addColumn = max(0, min(width - 1, x + radius))
                let removedValue = Float(luminance[base + removeColumn])
                let addedValue = Float(luminance[base + addColumn])
                runningSum += addedValue - removedValue
                runningSquaredSum += addedValue * addedValue - removedValue * removedValue
                sums[x] = runningSum
                squaredSums[x] = runningSquaredSum
            }

            return RowData(sums: sums, squaredSums: squaredSums)
        }

        var cachedRows: [Int: RowData] = [:]
        var referenceCounts: [Int: Int] = [:]

        func retainRow(_ row: Int) {
            let clamped = max(0, min(height - 1, row))
            if referenceCounts[clamped] == nil {
                cachedRows[clamped] = horizontalSums(for: clamped)
                referenceCounts[clamped] = 1
            } else {
                referenceCounts[clamped, default: 0] += 1
            }
        }

        func releaseRow(_ row: Int) {
            let clamped = max(0, min(height - 1, row))
            guard let count = referenceCounts[clamped] else { return }
            if count <= 1 {
                referenceCounts.removeValue(forKey: clamped)
                cachedRows.removeValue(forKey: clamped)
            } else {
                referenceCounts[clamped] = count - 1
            }
        }

        var windowRows: [Int] = []
        var verticalSums = [Float](repeating: 0, count: width)
        var verticalSquaredSums = [Float](repeating: 0, count: width)

        for offset in -radius...radius {
            let row = max(0, min(height - 1, offset))
            retainRow(row)
            windowRows.append(row)
            guard let rowData = cachedRows[row] else { continue }
            for x in 0..<width {
                verticalSums[x] += rowData.sums[x]
                verticalSquaredSums[x] += rowData.squaredSums[x]
            }
        }

        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width {
                let mean = verticalSums[x] / area
                let squaredMean = verticalSquaredSums[x] / area
                let variance = max(0.0, squaredMean - mean * mean)
                let stddev = sqrt(variance)
                let source = Float(luminance[rowBase + x])
                let threshold = mean * (1.0 + k * (stddev / dynamicRange - 1.0))
                let delta = mean - source
                let candidate = source <= threshold

                if candidate && delta >= max(10.0, stddev * 0.22) {
                    soft[rowBase + x] = 255
                }
                if candidate && delta >= max(22.0, stddev * 0.40) {
                    strong[rowBase + x] = 255
                }
            }

            guard y < height - 1 else { break }

            let removedRow = windowRows.removeFirst()
            if let removedData = cachedRows[removedRow] {
                for x in 0..<width {
                    verticalSums[x] -= removedData.sums[x]
                    verticalSquaredSums[x] -= removedData.squaredSums[x]
                }
            }
            releaseRow(removedRow)

            let addedRow = max(0, min(height - 1, y + radius + 1))
            retainRow(addedRow)
            windowRows.append(addedRow)
            if let addedData = cachedRows[addedRow] {
                for x in 0..<width {
                    verticalSums[x] += addedData.sums[x]
                    verticalSquaredSums[x] += addedData.squaredSums[x]
                }
            }
        }

        return (soft, strong)
    }

    private static func computeChroma(aChannel: [UInt8], bChannel: [UInt8]) -> [UInt8] {
        zip(aChannel, bChannel).map { aValue, bValue in
            let a = Float(Int(aValue) - 128)
            let b = Float(Int(bValue) - 128)
            return clampToUInt8(sqrt(a * a + b * b))
        }
    }

    private static func compressChroma(_ channel: [UInt8], factor: Float) -> [UInt8] {
        channel.map { value in
            clampToUInt8((Float(Int(value) - 128) * factor) + 128.0)
        }
    }

    private static func neutralizeColorChannel(_ channel: [UInt8], paperMean: Float) -> [UInt8] {
        channel.map { value in
            clampToUInt8(Float(value) - (paperMean - 128.0))
        }
    }

    private static func blendTowardValue(
        _ channel: [UInt8],
        mask: [UInt8],
        target: Float,
        strength: Float
    ) -> [UInt8] {
        zip(channel, mask).map { value, maskValue in
            let weight = (Float(maskValue) / 255.0) * strength
            let blended = Float(value) * (1.0 - weight) + target * weight
            return clampToUInt8(blended)
        }
    }

    private static func weightedBlend(
        _ left: [UInt8],
        _ right: [UInt8],
        weightA: Float,
        weightB: Float
    ) -> [UInt8] {
        zip(left, right).map { leftValue, rightValue in
            clampToUInt8(Float(leftValue) * weightA + Float(rightValue) * weightB)
        }
    }

    private static func blendMaskedTowardReference(
        _ base: [UInt8],
        reference: [UInt8],
        mask: [UInt8],
        referenceWeight: Float
    ) -> [UInt8] {
        var output = base
        for index in output.indices where mask[index] > 0 {
            output[index] = clampToUInt8(
                Float(base[index]) * (1.0 - referenceWeight) + Float(reference[index]) * referenceWeight
            )
        }
        return output
    }

    private static func computeSaturation(
        red: [UInt8],
        green: [UInt8],
        blue: [UInt8]
    ) -> [UInt8] {
        zip(zip(red, green), blue).map { rg, blueValue in
            let (redValue, greenValue) = rg
            let (_, saturation, _) = rgbToHSV(red: redValue, green: greenValue, blue: blueValue)
            return clampToUInt8(saturation * 255.0)
        }
    }

    private static func estimateColorRichness(_ referenceSaturation: [UInt8], visibleMask: [UInt8]) -> Double {
        var visibleCount = 0
        var colorCount = 0
        for index in referenceSaturation.indices where visibleMask[index] > 0 {
            visibleCount += 1
            if referenceSaturation[index] > 18 {
                colorCount += 1
            }
        }
        guard visibleCount > 0 else { return 0.0 }
        let colorDensity = Double(colorCount) / Double(visibleCount)
        return ((colorDensity - 0.025) / 0.14).clamped(to: 0.0...1.0)
    }

    private static func buildPaperColorMask(
        referenceSaturation: [UInt8],
        luminance: [UInt8],
        paperMask: [UInt8],
        accentMask: [UInt8],
        colorRichness: Double,
        width: Int,
        height: Int
    ) -> [UInt8] {
        let saturationMask = thresholdMask(
            referenceSaturation,
            threshold: Int(round(22.0 - 8.0 * colorRichness)),
            inverse: false
        )
        let visibleMask = thresholdMask(luminance, threshold: 48, inverse: false)
        var paperColorMask = bitwiseAnd(bitwiseAnd(saturationMask, visibleMask), paperMask)
        paperColorMask = bitwiseOr(paperColorMask, accentMask)
        return morphologyOpen(paperColorMask, radius: 1, iterations: 1, width: width, height: height)
    }

    private static func restoreContentSaturation(
        red: [UInt8],
        green: [UInt8],
        blue: [UInt8],
        referenceRed: [UInt8],
        referenceGreen: [UInt8],
        referenceBlue: [UInt8],
        luminance: [UInt8],
        paperMask: [UInt8],
        accentMask: [UInt8],
        paperColorMask: [UInt8]
    ) -> (red: [UInt8], green: [UInt8], blue: [UInt8]) {
        let referenceSaturation = computeSaturation(
            red: referenceRed,
            green: referenceGreen,
            blue: referenceBlue
        )
        let visibleMask = thresholdMask(luminance, threshold: 48, inverse: false)
        let colorRichness = estimateColorRichness(referenceSaturation, visibleMask: visibleMask)

        var outputRed = red
        var outputGreen = green
        var outputBlue = blue

        for index in red.indices where luminance[index] > 48 {
            let restorePixel = paperMask[index] == 0 || paperColorMask[index] > 0
            guard restorePixel else { continue }

            let referenceSaturationValue = Float(referenceSaturation[index])
            guard referenceSaturationValue > 10.0 else { continue }

            let preserveWeight = ((referenceSaturationValue - 10.0) / 34.0).clamped(to: 0.0...1.0)
            var saturationFloor = referenceSaturationValue * Float(
                0.40 + 0.24 * Double(preserveWeight) + 0.24 * colorRichness
            )
            if accentMask[index] > 0 {
                saturationFloor = max(
                    saturationFloor,
                    referenceSaturationValue * Float(0.74 + 0.18 * colorRichness)
                )
            }
            if paperColorMask[index] > 0 {
                saturationFloor = max(
                    saturationFloor,
                    referenceSaturationValue * Float(0.50 + 0.18 * colorRichness)
                )
            }

            var (hue, saturation, value) = rgbToHSV(
                red: outputRed[index],
                green: outputGreen[index],
                blue: outputBlue[index]
            )
            let floor = (saturationFloor / 255.0).clamped(to: 0.0...1.0)
            saturation = max(saturation, floor)
            let restored = hsvToRGB(hue: hue, saturation: saturation, value: value)
            outputRed[index] = restored.0
            outputGreen[index] = restored.1
            outputBlue[index] = restored.2
        }

        return (outputRed, outputGreen, outputBlue)
    }

    private static func applyChannelContrast(_ channel: [UInt8], value: Float) -> [UInt8] {
        let offset = 128.0 * (1.0 - value)
        return channel.map { pixel in
            clampToUInt8(Float(pixel) * value + offset)
        }
    }

    private static func thresholdMask(_ pixels: [UInt8], threshold: Int, inverse: Bool) -> [UInt8] {
        pixels.map { value in
            if inverse {
                return Int(value) <= threshold ? 255 : 0
            }
            return Int(value) > threshold ? 255 : 0
        }
    }

    private static func bitwiseAnd(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        zip(lhs, rhs).map { $0 & $1 }
    }

    private static func bitwiseOr(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        zip(lhs, rhs).map { $0 | $1 }
    }

    private static func bitwiseNot(_ pixels: [UInt8]) -> [UInt8] {
        pixels.map { ~$0 }
    }

    private static func morphologyClose(
        _ pixels: [UInt8],
        radius: Int,
        iterations: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var result = pixels
        for _ in 0..<iterations {
            result = morphologyMaximum(result, radius: radius, width: width, height: height)
            result = morphologyMinimum(result, radius: radius, width: width, height: height)
        }
        return result
    }

    private static func morphologyOpen(
        _ pixels: [UInt8],
        radius: Int,
        iterations: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var result = pixels
        for _ in 0..<iterations {
            result = morphologyMinimum(result, radius: radius, width: width, height: height)
            result = morphologyMaximum(result, radius: radius, width: width, height: height)
        }
        return result
    }

    private static func dilateMask(
        _ pixels: [UInt8],
        radius: Int,
        iterations: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var result = pixels
        for _ in 0..<iterations {
            result = morphologyMaximum(result, radius: radius, width: width, height: height)
        }
        return result
    }

    private static func morphologyMaximum(
        _ pixels: [UInt8],
        radius: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard radius > 0 else { return pixels }
        let source = makeGrayscaleImage(pixels, width: width, height: height).clampedToExtent()
        guard let filter = CIFilter(name: "CIMorphologyMaximum") else { return pixels }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        else { return pixels }
        return renderGrayscalePixels(output, width: width, height: height)
    }

    private static func morphologyMinimum(
        _ pixels: [UInt8],
        radius: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard radius > 0 else { return pixels }
        let source = makeGrayscaleImage(pixels, width: width, height: height).clampedToExtent()
        guard let filter = CIFilter(name: "CIMorphologyMinimum") else { return pixels }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        else { return pixels }
        return renderGrayscalePixels(output, width: width, height: height)
    }

    private static func gaussianBlur(
        _ pixels: [UInt8],
        sigma: Float,
        width: Int,
        height: Int
    ) -> [UInt8] {
        guard sigma > 0 else { return pixels }
        let source = makeGrayscaleImage(pixels, width: width, height: height).clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return pixels }
        filter.setValue(source, forKey: kCIInputImageKey)
        filter.setValue(sigma, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        else { return pixels }
        return renderGrayscalePixels(output, width: width, height: height)
    }

    private static func medianBlur3(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
        let source = makeGrayscaleImage(pixels, width: width, height: height).clampedToExtent()
        guard let filter = CIFilter(name: "CIMedianFilter") else { return pixels }
        filter.setValue(source, forKey: kCIInputImageKey)
        guard let output = filter.outputImage?.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        else { return pixels }
        return renderGrayscalePixels(output, width: width, height: height)
    }

    private static func makeGrayscaleImage(_ pixels: [UInt8], width: Int, height: Int) -> CIImage {
        var packed = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            let base = index * 4
            let value = pixels[index]
            packed[base] = value
            packed[base + 1] = value
            packed[base + 2] = value
        }

        let data = Data(packed)
        return CIImage(
            bitmapData: data,
            bytesPerRow: width * 4,
            size: CGSize(width: width, height: height),
            format: .RGBA8,
            colorSpace: nil
        )
    }

    private static func renderGrayscalePixels(_ image: CIImage, width: Int, height: Int) -> [UInt8] {
        var packed = [UInt8](repeating: 0, count: width * height * 4)
        rawContext.render(
            image,
            toBitmap: &packed,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: nil
        )

        var output = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            output[index] = packed[index * 4]
        }
        return output
    }

    private static func estimateBWToneCount(_ luminance: [UInt8]) -> Int {
        let hist = histogram(for: luminance)
        let total = luminance.count
        let q10 = percentile(from: hist, totalPixels: total, percentile: 0.10)
        let q50 = percentile(from: hist, totalPixels: total, percentile: 0.50)
        let lowTail = q50 - q10
        let midCount = hist[96..<220].reduce(0, +)
        let midRatio = total > 0 ? Float(midCount) / Float(total) : 0

        if q10 >= 232 && lowTail < 12 {
            return 2
        }
        if q10 >= 185 && lowTail < 60 && midRatio < 0.12 {
            return 3
        }
        return 4
    }

    private static func fitQuantizationLevels(_ luminance: [UInt8], toneCount: Int) -> [Int] {
        let baseHistogram = histogram(for: luminance)
        let darkerCount = baseHistogram[..<224].reduce(0, +)
        let brighterCount = baseHistogram[224...].reduce(0, +)
        let maxBrighter = min(brighterCount, max(darkerCount * 2, 12_000))
        let brighterScale = brighterCount > maxBrighter && brighterCount > 0
            ? Double(maxBrighter) / Double(brighterCount)
            : 1.0

        var weightedHistogram = baseHistogram.map(Double.init)
        if brighterScale < 1.0 {
            for index in 224..<weightedHistogram.count {
                weightedHistogram[index] *= brighterScale
            }
        }

        if toneCount == 2 {
            let threshold = otsuThreshold(weightedHistogram)
            let darkLevel = max(16, min(48, Int(round(Double(threshold) * 0.30))))
            return [darkLevel, 244]
        }

        var centers = initialCenters(histogram: weightedHistogram, clusterCount: toneCount)
        for _ in 0..<32 {
            var sums = [Double](repeating: 0, count: toneCount)
            var counts = [Double](repeating: 0, count: toneCount)

            for value in 0..<weightedHistogram.count where weightedHistogram[value] > 0 {
                let weight = weightedHistogram[value]
                var bestIndex = 0
                var bestDistance = abs(Double(value) - centers[0])
                for index in 1..<centers.count {
                    let distance = abs(Double(value) - centers[index])
                    if distance < bestDistance {
                        bestDistance = distance
                        bestIndex = index
                    }
                }
                sums[bestIndex] += Double(value) * weight
                counts[bestIndex] += weight
            }

            var updated = centers
            for index in 0..<toneCount where counts[index] > 0 {
                updated[index] = sums[index] / counts[index]
            }
            let delta = zip(updated, centers).map { abs($0 - $1) }.max() ?? 0
            centers = updated
            if delta < 0.2 {
                break
            }
        }

        var ordered = centers.map { Int(round($0)) }.sorted()
        if toneCount == 3 {
            ordered[0] = max(16, min(52, ordered[0]))
            ordered[1] = max(112, min(188, ordered[1]))
            ordered[2] = max(236, ordered[2])
        } else {
            ordered[0] = max(16, min(56, ordered[0]))
            ordered[1] = max(72, min(132, ordered[1]))
            ordered[2] = max(136, min(196, ordered[2]))
            ordered[3] = max(236, ordered[3])
        }

        var deduped: [Int] = []
        for level in ordered {
            if let last = deduped.last, level <= last {
                deduped.append(min(244, last + 8))
            } else {
                deduped.append(level)
            }
        }
        return deduped
    }

    private static func initialCenters(histogram: [Double], clusterCount: Int) -> [Double] {
        let total = histogram.reduce(0, +)
        guard total > 0 else {
            return (0..<clusterCount).map { Double(($0 + 1) * 255 / (clusterCount + 1)) }
        }

        return (0..<clusterCount).map { index in
            let target = total * Double(index + 1) / Double(clusterCount + 1)
            var cumulative = 0.0
            for value in 0..<histogram.count {
                cumulative += histogram[value]
                if cumulative >= target {
                    return Double(value)
                }
            }
            return 255.0
        }
    }

    private static func otsuThreshold(_ histogram: [Double]) -> Int {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 127 }

        let weightedTotal = histogram.enumerated().reduce(0.0) { partial, item in
            partial + Double(item.offset) * item.element
        }

        var backgroundWeight = 0.0
        var backgroundWeightedSum = 0.0
        var bestVariance = -1.0
        var bestThreshold = 127

        for threshold in 0..<histogram.count {
            backgroundWeight += histogram[threshold]
            backgroundWeightedSum += Double(threshold) * histogram[threshold]
            let foregroundWeight = total - backgroundWeight

            guard backgroundWeight > 0, foregroundWeight > 0 else { continue }

            let backgroundMean = backgroundWeightedSum / backgroundWeight
            let foregroundMean = (weightedTotal - backgroundWeightedSum) / foregroundWeight
            let delta = backgroundMean - foregroundMean
            let variance = backgroundWeight * foregroundWeight * delta * delta

            if variance > bestVariance {
                bestVariance = variance
                bestThreshold = threshold
            }
        }

        return bestThreshold
    }

    private static func quantizeWithLevels(_ luminance: [UInt8], levels: [Int]) -> [UInt8] {
        guard !levels.isEmpty else { return luminance }
        let thresholds = zip(levels, levels.dropFirst()).map { Int(round(Double($0 + $1) / 2.0)) }
        return luminance.map { value in
            let intValue = Int(value)
            for (index, threshold) in thresholds.enumerated() where intValue < threshold {
                return UInt8(levels[index])
            }
            return UInt8(levels[levels.count - 1])
        }
    }

    private static func histogram(for pixels: [UInt8]) -> [Int] {
        var histogram = [Int](repeating: 0, count: 256)
        for value in pixels {
            histogram[Int(value)] += 1
        }
        return histogram
    }

    private static func percentile(_ pixels: [UInt8], percentile p: Double) -> Int {
        percentile(from: histogram(for: pixels), totalPixels: pixels.count, percentile: p)
    }

    private static func percentile(
        from histogram: [Int],
        totalPixels: Int,
        percentile: Double
    ) -> Int {
        let target = max(0, min(totalPixels - 1, Int(Double(totalPixels) * percentile)))
        var cumulative = 0
        for value in 0..<histogram.count {
            cumulative += histogram[value]
            if cumulative > target {
                return value
            }
        }
        return 255
    }

    private static func meanValue(_ pixels: [UInt8]) -> Float {
        guard !pixels.isEmpty else { return 0 }
        let total = pixels.reduce(0) { $0 + Int($1) }
        return Float(total) / Float(pixels.count)
    }

    private static func meanMaskedValue(_ pixels: [UInt8], mask: [UInt8]) -> Float? {
        var total: Int = 0
        var count: Int = 0
        for index in pixels.indices where mask[index] > 0 {
            total += Int(pixels[index])
            count += 1
        }
        guard count > 0 else { return nil }
        return Float(total) / Float(count)
    }

    private static func rgbToHSV(red: UInt8, green: UInt8, blue: UInt8) -> (Float, Float, Float) {
        let red = Float(red) / 255.0
        let green = Float(green) / 255.0
        let blue = Float(blue) / 255.0

        let maxValue = max(red, green, blue)
        let minValue = min(red, green, blue)
        let delta = maxValue - minValue

        let hue: Float
        if delta == 0 {
            hue = 0
        } else if maxValue == red {
            hue = ((green - blue) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxValue == green {
            hue = ((blue - red) / delta) + 2.0
        } else {
            hue = ((red - green) / delta) + 4.0
        }

        let normalizedHue = hue < 0 ? hue + 6.0 : hue
        let saturation = maxValue == 0 ? 0 : delta / maxValue
        return (normalizedHue / 6.0, saturation, maxValue)
    }

    private static func hsvToRGB(hue: Float, saturation: Float, value: Float) -> (UInt8, UInt8, UInt8) {
        if saturation <= 0 {
            let gray = clampToUInt8(value * 255.0)
            return (gray, gray, gray)
        }

        let scaledHue = hue * 6.0
        let sector = Int(floor(scaledHue)) % 6
        let fraction = scaledHue - floor(scaledHue)
        let p = value * (1.0 - saturation)
        let q = value * (1.0 - fraction * saturation)
        let t = value * (1.0 - (1.0 - fraction) * saturation)

        let rgb: (Float, Float, Float)
        switch sector {
        case 0:
            rgb = (value, t, p)
        case 1:
            rgb = (q, value, p)
        case 2:
            rgb = (p, value, t)
        case 3:
            rgb = (p, q, value)
        case 4:
            rgb = (t, p, value)
        default:
            rgb = (value, p, q)
        }

        return (
            clampToUInt8(rgb.0 * 255.0),
            clampToUInt8(rgb.1 * 255.0),
            clampToUInt8(rgb.2 * 255.0)
        )
    }

    private static func clampToUInt8(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(round(value)))))
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
