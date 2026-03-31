package io.github.yusukeiwaki.camscanshare.data.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import androidx.camera.core.ImageProxy
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.core.TermCriteria
import org.opencv.imgproc.Imgproc
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ImageProcessor @Inject constructor() {

    init {
        OpenCVLoader.initLocal()
    }

    fun toBitmapWithCorrectRotation(imageProxy: ImageProxy): Bitmap {
        val bitmap = imageProxy.toBitmap()
        val rotationDegrees = imageProxy.imageInfo.rotationDegrees
        return if (rotationDegrees != 0) {
            rotateBitmap(bitmap, rotationDegrees.toFloat())
        } else {
            bitmap
        }
    }

    fun rotateBitmap(source: Bitmap, degrees: Float): Bitmap {
        if (degrees == 0f) return source
        val matrix = Matrix().apply { postRotate(degrees) }
        return Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true)
    }

    /**
     * Apply a filter to a bitmap. "magic", "bw", and "whiteboard" use
     * OpenCV pipelines matching the docs evaluation logic; lightweight color
     * presets continue to use ColorMatrix.
     */
    fun applyFilter(source: Bitmap, filterKey: String): Bitmap {
        when (filterKey) {
            "magic" -> return applyMagicFilter(source)
            "bw" -> return applyDocumentBwFilter(source)
            "whiteboard" -> return applyWhiteboardFilter(source)
        }

        val colorMatrix = getColorMatrix(filterKey) ?: return source
        val result = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(result)
        val paint = Paint().apply {
            colorFilter = ColorMatrixColorFilter(colorMatrix)
        }
        canvas.drawBitmap(source, 0f, 0f, paint)
        return result
    }

    /**
     * Get the ColorMatrix for a given filter key. Returns null for filters
     * handled by the OpenCV pipelines.
     */
    fun getColorMatrix(filterKey: String): ColorMatrix? = when (filterKey) {
        "original" -> null
        "magic" -> null
        "sharpen" -> contrastMatrix(1.4f).apply { postConcat(brightnessMatrix(1.05f)) }
        "bw" -> null
        "whiteboard" -> null
        "vivid" -> saturationMatrix(2f).apply { postConcat(contrastMatrix(1.2f)) }
        else -> null
    }

    /**
     * Magic filter: deterministic document enhancement.
     *
     * 1. Flatten illumination on Lab-L
     * 2. Auto-select black/white points from the luminance histogram
     * 3. Neutralize paper color cast
     * 4. Desaturate neutral content while preserving strong accent colors
     */
    private fun applyMagicFilter(source: Bitmap): Bitmap {
        val mat = Mat()
        Utils.bitmapToMat(source, mat)
        val rgb = Mat()
        Imgproc.cvtColor(mat, rgb, Imgproc.COLOR_RGBA2RGB)

        val lab = Mat()
        Imgproc.cvtColor(rgb, lab, Imgproc.COLOR_RGB2Lab)

        val channels = ArrayList<Mat>(3)
        Core.split(lab, channels)
        val luminance = channels[0]
        val aChannel = channels[1]
        val bChannel = channels[2]

        val illumination = estimateIllumination(luminance)
        val flattenedL = flatFieldCorrect(luminance, illumination)
        val stretchedL = autoStretchLuminance(flattenedL)
        val denoisedL = Mat()
        Imgproc.medianBlur(stretchedL, denoisedL, 3)

        val paperMask = buildPaperMask(denoisedL, aChannel, bChannel)
        val structureMask = buildStructureMask(denoisedL)
        val invertedStructureMask = invertMask(structureMask)
        Core.bitwise_and(paperMask, invertedStructureMask, paperMask)
        val paperCloseKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        Imgproc.morphologyEx(
            paperMask,
            paperMask,
            Imgproc.MORPH_CLOSE,
            paperCloseKernel,
            org.opencv.core.Point(-1.0, -1.0),
            2,
        )

        val accentMask = buildAccentMask(denoisedL, aChannel, bChannel)

        val paperBias = estimatePaperBias(aChannel, bChannel, paperMask)
        val neutralizedA = shiftChannel(aChannel, paperBias.first - 128.0)
        val neutralizedB = shiftChannel(bChannel, paperBias.second - 128.0)

        val mutedA = compressChroma(neutralizedA, 0.18)
        val mutedB = compressChroma(neutralizedB, 0.18)
        val accentA = compressChroma(neutralizedA, 0.85)
        val accentB = compressChroma(neutralizedB, 0.85)

        val outputL = blendTowardValue(denoisedL, paperMask, 244.0, 0.34)
        val blendedL = Mat()
        Core.addWeighted(outputL, 0.58, denoisedL, 0.42, 0.0, blendedL)
        val outputA = Mat(mutedA.size(), mutedA.type())
        val outputB = Mat(mutedB.size(), mutedB.type())
        mutedA.copyTo(outputA)
        mutedB.copyTo(outputB)
        accentA.copyTo(outputA, accentMask)
        accentB.copyTo(outputB, accentMask)
        outputA.setTo(Scalar.all(128.0), paperMask)
        outputB.setTo(Scalar.all(128.0), paperMask)

        val resultLab = Mat()
        Core.merge(listOf(blendedL, outputA, outputB), resultLab)

        val resultRgb = Mat()
        Imgproc.cvtColor(resultLab, resultRgb, Imgproc.COLOR_Lab2RGB)

        val resultRgba = Mat()
        Imgproc.cvtColor(resultRgb, resultRgba, Imgproc.COLOR_RGB2RGBA)

        val output = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(resultRgba, output)

        mat.release()
        rgb.release()
        lab.release()
        luminance.release()
        aChannel.release()
        bChannel.release()
        illumination.release()
        flattenedL.release()
        stretchedL.release()
        denoisedL.release()
        paperMask.release()
        structureMask.release()
        invertedStructureMask.release()
        paperCloseKernel.release()
        accentMask.release()
        neutralizedA.release()
        neutralizedB.release()
        mutedA.release()
        mutedB.release()
        accentA.release()
        accentB.release()
        outputL.release()
        blendedL.release()
        outputA.release()
        outputB.release()
        resultLab.release()
        resultRgb.release()
        resultRgba.release()

        return output
    }

    private fun applyDocumentBwFilter(source: Bitmap): Bitmap {
        val rgba = Mat()
        Utils.bitmapToMat(source, rgba)
        val rgb = Mat()
        Imgproc.cvtColor(rgba, rgb, Imgproc.COLOR_RGBA2RGB)

        val originalWidth = rgb.width()
        val originalHeight = rgb.height()
        val upscale = maxOf(originalWidth, originalHeight) < 1400
        val workingRgb = Mat()
        if (upscale) {
            Imgproc.resize(
                rgb,
                workingRgb,
                Size((originalWidth * 2).toDouble(), (originalHeight * 2).toDouble()),
                0.0,
                0.0,
                Imgproc.INTER_CUBIC,
            )
        } else {
            rgb.copyTo(workingRgb)
        }

        val lab = Mat()
        Imgproc.cvtColor(workingRgb, lab, Imgproc.COLOR_RGB2Lab)
        val channels = ArrayList<Mat>(3)
        Core.split(lab, channels)
        val luminance = channels[0]
        val aChannel = channels[1]
        val bChannel = channels[2]

        val illumination = estimateIllumination(luminance)
        val flattenedL = flatFieldCorrect(luminance, illumination)
        val stretchedL = autoStretchLuminance(flattenedL)
        val denoisedL = Mat()
        Imgproc.medianBlur(stretchedL, denoisedL, 3)
        val emphasizedL = applyChannelContrast(denoisedL, 1.48)

        val paperMask = buildPaperMask(denoisedL, aChannel, bChannel)
        val (softStructure0, strongStructure0) = buildSauvolaStructureMasks(emphasizedL)

        val darkMask = Mat()
        val darkThreshold = maxOf(70.0, percentileOfMat(denoisedL, 0.12))
        Imgproc.threshold(denoisedL, darkMask, darkThreshold, 255.0, Imgproc.THRESH_BINARY_INV)

        val strongStructure = Mat()
        Core.bitwise_or(strongStructure0, darkMask, strongStructure)
        val softStructure = softStructure0.clone()

        val kernel3 = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        Imgproc.dilate(softStructure, softStructure, kernel3, org.opencv.core.Point(-1.0, -1.0), 1)
        Imgproc.dilate(strongStructure, strongStructure, kernel3, org.opencv.core.Point(-1.0, -1.0), 1)

        val structureMask = Mat()
        Core.bitwise_or(softStructure, strongStructure, structureMask)
        Imgproc.medianBlur(structureMask, structureMask, 3)

        val invertedStructureMask = invertMask(structureMask)
        Core.bitwise_and(paperMask, invertedStructureMask, paperMask)
        val kernel5 = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        Imgproc.morphologyEx(
            paperMask,
            paperMask,
            Imgproc.MORPH_CLOSE,
            kernel5,
            org.opencv.core.Point(-1.0, -1.0),
            2,
        )

        val tonedL0 = blendTowardValue(emphasizedL, paperMask, 246.0, 0.44)
        val tonedL = maskedMinScaled(tonedL0, emphasizedL, structureMask, 0.92)

        val brightBackground = Mat()
        Imgproc.threshold(tonedL, brightBackground, 182.0, 255.0, Imgproc.THRESH_BINARY)
        Core.bitwise_and(brightBackground, invertedStructureMask, brightBackground)
        val quantizeSource = blendTowardValue(tonedL, brightBackground, 236.0, 0.32)
        Imgproc.GaussianBlur(quantizeSource, quantizeSource, Size(3.0, 3.0), 0.0)

        val toneCount = estimateBwToneCount(quantizeSource)
        val sample = buildQuantizationSample(quantizeSource)
        val levels = fitQuantizationLevels(sample, toneCount)
        val quantized = quantizeWithLevels(quantizeSource, levels)
        applyPaperFloor(quantized, paperMask, levels, toneCount)

        val bwRgb = Mat()
        Core.merge(listOf(quantized, quantized, quantized), bwRgb)

        val outputRgb = Mat()
        if (upscale) {
            Imgproc.resize(bwRgb, outputRgb, Size(originalWidth.toDouble(), originalHeight.toDouble()), 0.0, 0.0, Imgproc.INTER_AREA)
        } else {
            bwRgb.copyTo(outputRgb)
        }

        val output = bitmapFromRgb(outputRgb, source.width, source.height)

        rgba.release()
        rgb.release()
        workingRgb.release()
        lab.release()
        luminance.release()
        aChannel.release()
        bChannel.release()
        illumination.release()
        flattenedL.release()
        stretchedL.release()
        denoisedL.release()
        emphasizedL.release()
        paperMask.release()
        softStructure0.release()
        strongStructure0.release()
        darkMask.release()
        strongStructure.release()
        softStructure.release()
        kernel3.release()
        structureMask.release()
        invertedStructureMask.release()
        kernel5.release()
        tonedL0.release()
        tonedL.release()
        brightBackground.release()
        quantizeSource.release()
        quantized.release()
        bwRgb.release()
        outputRgb.release()

        return output
    }

    private fun applyWhiteboardFilter(source: Bitmap): Bitmap {
        val rgba = Mat()
        Utils.bitmapToMat(source, rgba)
        val rgb = Mat()
        Imgproc.cvtColor(rgba, rgb, Imgproc.COLOR_RGBA2RGB)

        val lab = Mat()
        Imgproc.cvtColor(rgb, lab, Imgproc.COLOR_RGB2Lab)
        val channels = ArrayList<Mat>(3)
        Core.split(lab, channels)
        val luminance = channels[0]
        val aChannel = channels[1]
        val bChannel = channels[2]

        val illumination = estimateIllumination(luminance)
        val flattenedL = flatFieldCorrect(luminance, illumination)
        val stretchedL = autoStretchLuminance(flattenedL)
        val denoisedL = Mat()
        Imgproc.medianBlur(stretchedL, denoisedL, 3)

        val chroma = computeChroma(aChannel, bChannel)
        val accentMask0 = buildAccentMask(denoisedL, aChannel, bChannel)
        val mediumChromaMask = Mat()
        Imgproc.threshold(chroma, mediumChromaMask, 18.0, 255.0, Imgproc.THRESH_BINARY)
        val visibleMask = Mat()
        Imgproc.threshold(denoisedL, visibleMask, 42.0, 255.0, Imgproc.THRESH_BINARY)
        val extraAccentMask = Mat()
        Core.bitwise_and(mediumChromaMask, visibleMask, extraAccentMask)
        val accentMask = Mat()
        Core.bitwise_or(accentMask0, extraAccentMask, accentMask)
        val accentKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        Imgproc.morphologyEx(accentMask, accentMask, Imgproc.MORPH_OPEN, accentKernel)
        val accentProtectMask = Mat()
        Imgproc.dilate(accentMask, accentProtectMask, accentKernel, org.opencv.core.Point(-1.0, -1.0), 1)

        val structureMask0 = buildStructureMask(denoisedL)
        val contrastedL = applyChannelContrast(denoisedL, 1.22)
        val (_, sauvolaStrong) = buildSauvolaStructureMasks(
            contrastedL,
            windowSize = 35,
            k = 0.16,
            dynamicRange = 128.0,
        )
        val structureMask = Mat()
        Core.bitwise_or(structureMask0, sauvolaStrong, structureMask)
        Core.bitwise_or(structureMask, accentProtectMask, structureMask)
        Imgproc.medianBlur(structureMask, structureMask, 3)
        Imgproc.dilate(structureMask, structureMask, accentKernel, org.opencv.core.Point(-1.0, -1.0), 1)

        val paperMask = buildPaperMask(denoisedL, aChannel, bChannel)
        val brightMask = Mat()
        val brightThreshold = maxOf(156.0, percentileOfMat(denoisedL, 0.58))
        Imgproc.threshold(denoisedL, brightMask, brightThreshold, 255.0, Imgproc.THRESH_BINARY)
        Core.bitwise_or(paperMask, brightMask, paperMask)
        val invertedStructureMask = invertMask(structureMask)
        val invertedAccentProtectMask = invertMask(accentProtectMask)
        Core.bitwise_and(paperMask, invertedStructureMask, paperMask)
        Core.bitwise_and(paperMask, invertedAccentProtectMask, paperMask)
        val kernel5 = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        Imgproc.morphologyEx(
            paperMask,
            paperMask,
            Imgproc.MORPH_CLOSE,
            kernel5,
            org.opencv.core.Point(-1.0, -1.0),
            2,
        )

        val paperBias = estimatePaperBias(aChannel, bChannel, paperMask)
        val neutralizedA = shiftChannel(aChannel, paperBias.first - 128.0)
        val neutralizedB = shiftChannel(bChannel, paperBias.second - 128.0)

        val mutedA = compressChroma(neutralizedA, 0.42)
        val mutedB = compressChroma(neutralizedB, 0.42)
        val accentA = compressChroma(neutralizedA, 1.32)
        val accentB = compressChroma(neutralizedB, 1.32)

        val outputL0 = blendTowardValue(denoisedL, paperMask, 250.0, 0.50)
        val outputL1 = Mat()
        Core.addWeighted(outputL0, 0.68, denoisedL, 0.32, 0.0, outputL1)
        val outputL2 = maskedMinScaled(outputL1, denoisedL, sauvolaStrong, 0.84)
        val outputL = maskedMinScaled(outputL2, denoisedL, accentProtectMask, 0.92)

        val outputA = Mat(mutedA.size(), mutedA.type())
        val outputB = Mat(mutedB.size(), mutedB.type())
        mutedA.copyTo(outputA)
        mutedB.copyTo(outputB)
        accentA.copyTo(outputA, accentMask)
        accentB.copyTo(outputB, accentMask)
        outputA.setTo(Scalar.all(128.0), paperMask)
        outputB.setTo(Scalar.all(128.0), paperMask)

        val finalLab = Mat()
        Core.merge(listOf(outputL, outputA, outputB), finalLab)
        val finalRgb = Mat()
        Imgproc.cvtColor(finalLab, finalRgb, Imgproc.COLOR_Lab2RGB)
        val finalBgr = Mat()
        Imgproc.cvtColor(finalRgb, finalBgr, Imgproc.COLOR_RGB2BGR)
        val boostedBgr = boostWhiteboardAccentColors(finalBgr, accentMask)
        val boostedRgb = Mat()
        Imgproc.cvtColor(boostedBgr, boostedRgb, Imgproc.COLOR_BGR2RGB)

        val output = bitmapFromRgb(boostedRgb, source.width, source.height)

        rgba.release()
        rgb.release()
        lab.release()
        luminance.release()
        aChannel.release()
        bChannel.release()
        illumination.release()
        flattenedL.release()
        stretchedL.release()
        denoisedL.release()
        chroma.release()
        accentMask0.release()
        mediumChromaMask.release()
        visibleMask.release()
        extraAccentMask.release()
        accentMask.release()
        accentKernel.release()
        accentProtectMask.release()
        structureMask0.release()
        contrastedL.release()
        sauvolaStrong.release()
        structureMask.release()
        paperMask.release()
        brightMask.release()
        invertedStructureMask.release()
        invertedAccentProtectMask.release()
        kernel5.release()
        neutralizedA.release()
        neutralizedB.release()
        mutedA.release()
        mutedB.release()
        accentA.release()
        accentB.release()
        outputL0.release()
        outputL1.release()
        outputL2.release()
        outputL.release()
        outputA.release()
        outputB.release()
        finalLab.release()
        finalRgb.release()
        finalBgr.release()
        boostedBgr.release()
        boostedRgb.release()

        return output
    }

    private fun estimateIllumination(luminance: Mat): Mat {
        val minSide = minOf(luminance.width(), luminance.height())
        val scale = if (minSide > 1024) 1024.0 / minSide else 1.0

        val working = Mat()
        if (scale < 1.0) {
            Imgproc.resize(
                luminance,
                working,
                Size(luminance.width() * scale, luminance.height() * scale),
                0.0,
                0.0,
                Imgproc.INTER_AREA,
            )
        } else {
            luminance.copyTo(working)
        }

        val kernelSide = maxOf(15, ((minOf(working.width(), working.height()) / 24.0).toInt() or 1))
        val kernel = Imgproc.getStructuringElement(
            Imgproc.MORPH_ELLIPSE,
            Size(kernelSide.toDouble(), kernelSide.toDouble()),
        )
        val closed = Mat()
        Imgproc.morphologyEx(working, closed, Imgproc.MORPH_CLOSE, kernel)

        val blurred = Mat()
        val sigma = maxOf(12.0, minOf(80.0, minOf(working.width(), working.height()) / 18.0))
        Imgproc.GaussianBlur(closed, blurred, Size(0.0, 0.0), sigma)

        val illumination = Mat()
        if (scale < 1.0) {
            Imgproc.resize(blurred, illumination, luminance.size(), 0.0, 0.0, Imgproc.INTER_CUBIC)
        } else {
            blurred.copyTo(illumination)
        }

        working.release()
        kernel.release()
        closed.release()
        blurred.release()

        return illumination
    }

    private fun flatFieldCorrect(luminance: Mat, illumination: Mat): Mat {
        val luminance32 = Mat()
        val illumination32 = Mat()
        luminance.convertTo(luminance32, CvType.CV_32F)
        illumination.convertTo(illumination32, CvType.CV_32F)
        Core.add(luminance32, Scalar.all(1.0), luminance32)
        Core.add(illumination32, Scalar.all(1.0), illumination32)

        val corrected32 = Mat()
        Core.divide(luminance32, illumination32, corrected32, Core.mean(illumination).`val`[0])

        val corrected = Mat()
        corrected32.convertTo(corrected, CvType.CV_8U)

        luminance32.release()
        illumination32.release()
        corrected32.release()

        return corrected
    }

    private fun autoStretchLuminance(luminance: Mat): Mat {
        val histogram = IntArray(256)
        val totalPixels = luminance.rows() * luminance.cols()
        for (y in 0 until luminance.rows()) {
            for (x in 0 until luminance.cols()) {
                val value = luminance.get(y, x)[0].toInt().coerceIn(0, 255)
                histogram[value]++
            }
        }

        val blackPoint = findPercentile(histogram, totalPixels, 0.005)
        val whitePoint = findPercentile(histogram, totalPixels, 0.995).coerceAtLeast(blackPoint + 1)

        val clipped = Mat()
        Imgproc.threshold(luminance, clipped, whitePoint.toDouble(), 255.0, Imgproc.THRESH_TRUNC)

        val stretched32 = Mat()
        clipped.convertTo(stretched32, CvType.CV_32F)
        Core.subtract(stretched32, Scalar.all(blackPoint.toDouble()), stretched32)
        val scale = 255.0 / (whitePoint - blackPoint).toDouble()
        Core.multiply(stretched32, Scalar.all(scale), stretched32)

        val stretched = Mat()
        stretched32.convertTo(stretched, CvType.CV_8U)

        clipped.release()
        stretched32.release()

        return stretched
    }

    private fun findPercentile(histogram: IntArray, totalPixels: Int, percentile: Double): Int {
        val target = (totalPixels * percentile).toInt().coerceIn(0, totalPixels - 1)
        var cumulative = 0
        for (value in histogram.indices) {
            cumulative += histogram[value]
            if (cumulative > target) return value
        }
        return histogram.lastIndex
    }

    private fun buildPaperMask(luminance: Mat, aChannel: Mat, bChannel: Mat): Mat {
        val chroma = computeChroma(aChannel, bChannel)
        val brightThreshold = maxOf(96.0, percentileOfMat(luminance, 0.18))
        val brightMask = Mat()
        Imgproc.threshold(luminance, brightMask, brightThreshold, 255.0, Imgproc.THRESH_BINARY)
        val lowChromaMask = Mat()
        Imgproc.threshold(chroma, lowChromaMask, 34.0, 255.0, Imgproc.THRESH_BINARY_INV)

        val paperMask = Mat()
        Core.bitwise_and(brightMask, lowChromaMask, paperMask)

        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        Imgproc.morphologyEx(
            paperMask,
            paperMask,
            Imgproc.MORPH_CLOSE,
            kernel,
            org.opencv.core.Point(-1.0, -1.0),
            2,
        )
        Imgproc.morphologyEx(paperMask, paperMask, Imgproc.MORPH_OPEN, kernel)

        chroma.release()
        brightMask.release()
        lowChromaMask.release()
        kernel.release()

        return paperMask
    }

    private fun buildStructureMask(luminance: Mat): Mat {
        val adaptive = Mat()
        Imgproc.adaptiveThreshold(
            luminance,
            adaptive,
            255.0,
            Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
            Imgproc.THRESH_BINARY_INV,
            31,
            9.0,
        )

        val dark = Mat()
        val darkThreshold = maxOf(72.0, percentileOfMat(luminance, 0.10))
        Imgproc.threshold(luminance, dark, darkThreshold, 255.0, Imgproc.THRESH_BINARY_INV)

        val structureMask = Mat()
        Core.bitwise_or(adaptive, dark, structureMask)

        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        Imgproc.morphologyEx(structureMask, structureMask, Imgproc.MORPH_OPEN, kernel)
        Imgproc.dilate(structureMask, structureMask, kernel, org.opencv.core.Point(-1.0, -1.0), 2)

        adaptive.release()
        dark.release()
        kernel.release()

        return structureMask
    }

    private fun buildAccentMask(luminance: Mat, aChannel: Mat, bChannel: Mat): Mat {
        val chroma = computeChroma(aChannel, bChannel)
        val strongChromaMask = Mat()
        Imgproc.threshold(chroma, strongChromaMask, 28.0, 255.0, Imgproc.THRESH_BINARY)
        val visibleMask = Mat()
        Imgproc.threshold(luminance, visibleMask, 48.0, 255.0, Imgproc.THRESH_BINARY)

        val accentMask = Mat()
        Core.bitwise_and(strongChromaMask, visibleMask, accentMask)

        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        Imgproc.morphologyEx(accentMask, accentMask, Imgproc.MORPH_OPEN, kernel)

        chroma.release()
        strongChromaMask.release()
        visibleMask.release()
        kernel.release()

        return accentMask
    }

    private fun computeChroma(aChannel: Mat, bChannel: Mat): Mat {
        val a32 = Mat()
        val b32 = Mat()
        aChannel.convertTo(a32, CvType.CV_32F)
        bChannel.convertTo(b32, CvType.CV_32F)
        Core.subtract(a32, Scalar.all(128.0), a32)
        Core.subtract(b32, Scalar.all(128.0), b32)

        val aSq = Mat()
        val bSq = Mat()
        Core.multiply(a32, a32, aSq)
        Core.multiply(b32, b32, bSq)

        val chroma32 = Mat()
        Core.add(aSq, bSq, chroma32)
        Core.sqrt(chroma32, chroma32)

        val chroma = Mat()
        chroma32.convertTo(chroma, CvType.CV_8U)

        a32.release()
        b32.release()
        aSq.release()
        bSq.release()
        chroma32.release()

        return chroma
    }

    private fun estimatePaperBias(aChannel: Mat, bChannel: Mat, paperMask: Mat): Pair<Double, Double> {
        val paperPixels = Core.countNonZero(paperMask)
        if (paperPixels == 0) return 128.0 to 128.0

        val meanA = Core.mean(aChannel, paperMask).`val`[0]
        val meanB = Core.mean(bChannel, paperMask).`val`[0]
        return meanA to meanB
    }

    private fun percentileOfMat(channel: Mat, percentile: Double): Double {
        val histogram = IntArray(256)
        val totalPixels = channel.rows() * channel.cols()
        for (y in 0 until channel.rows()) {
            for (x in 0 until channel.cols()) {
                val value = channel.get(y, x)[0].toInt().coerceIn(0, 255)
                histogram[value]++
            }
        }
        return findPercentile(histogram, totalPixels, percentile).toDouble()
    }

    private fun invertMask(mask: Mat): Mat {
        val inverted = Mat()
        Core.bitwise_not(mask, inverted)
        return inverted
    }

    private fun shiftChannel(channel: Mat, bias: Double): Mat {
        val shifted32 = Mat()
        channel.convertTo(shifted32, CvType.CV_32F)
        Core.subtract(shifted32, Scalar.all(bias), shifted32)

        val shifted = Mat()
        shifted32.convertTo(shifted, CvType.CV_8U)
        shifted32.release()
        return shifted
    }

    private fun compressChroma(channel: Mat, factor: Double): Mat {
        val channel32 = Mat()
        channel.convertTo(channel32, CvType.CV_32F)
        Core.subtract(channel32, Scalar.all(128.0), channel32)
        Core.multiply(channel32, Scalar.all(factor), channel32)
        Core.add(channel32, Scalar.all(128.0), channel32)

        val compressed = Mat()
        channel32.convertTo(compressed, CvType.CV_8U)
        channel32.release()
        return compressed
    }

    private fun blendTowardValue(channel: Mat, mask: Mat, target: Double, strength: Double): Mat {
        val channel32 = Mat()
        val mask32 = Mat()
        channel.convertTo(channel32, CvType.CV_32F)
        mask.convertTo(mask32, CvType.CV_32F, strength / 255.0)

        val inverseMask = Mat(mask.size(), CvType.CV_32F, Scalar.all(1.0))
        Core.subtract(inverseMask, mask32, inverseMask)

        val preserved = Mat()
        Core.multiply(channel32, inverseMask, preserved)

        val targetContribution = Mat(mask.size(), CvType.CV_32F, Scalar.all(target))
        Core.multiply(targetContribution, mask32, targetContribution)

        val blended32 = Mat()
        Core.add(preserved, targetContribution, blended32)

        val blended = Mat()
        blended32.convertTo(blended, CvType.CV_8U)

        channel32.release()
        mask32.release()
        inverseMask.release()
        preserved.release()
        targetContribution.release()
        blended32.release()

        return blended
    }

    private fun applyChannelContrast(channel: Mat, value: Double): Mat {
        val channel32 = Mat()
        channel.convertTo(channel32, CvType.CV_32F)
        Core.multiply(channel32, Scalar.all(value), channel32)
        Core.add(channel32, Scalar.all(128.0 * (1.0 - value)), channel32)

        val contrasted = Mat()
        channel32.convertTo(contrasted, CvType.CV_8U)
        channel32.release()
        return contrasted
    }

    private fun computeLocalMeanStd(
        luminance: Mat,
        windowSize: Int = 31,
    ): Pair<Mat, Mat> {
        val source = Mat()
        luminance.convertTo(source, CvType.CV_32F)

        val mean = Mat()
        Imgproc.boxFilter(
            source,
            mean,
            CvType.CV_32F,
            Size(windowSize.toDouble(), windowSize.toDouble()),
            org.opencv.core.Point(-1.0, -1.0),
            true,
            Core.BORDER_REPLICATE,
        )

        val sourceSq = Mat()
        Core.multiply(source, source, sourceSq)
        val sqMean = Mat()
        Imgproc.boxFilter(
            sourceSq,
            sqMean,
            CvType.CV_32F,
            Size(windowSize.toDouble(), windowSize.toDouble()),
            org.opencv.core.Point(-1.0, -1.0),
            true,
            Core.BORDER_REPLICATE,
        )

        val meanSq = Mat()
        Core.multiply(mean, mean, meanSq)
        val variance = Mat()
        Core.subtract(sqMean, meanSq, variance)
        val zero = Mat(variance.size(), variance.type(), Scalar.all(0.0))
        Core.max(variance, zero, variance)

        val stddev = Mat()
        Core.sqrt(variance, stddev)

        source.release()
        sourceSq.release()
        sqMean.release()
        meanSq.release()
        variance.release()
        zero.release()

        return mean to stddev
    }

    private fun buildSauvolaStructureMasks(
        luminance: Mat,
        windowSize: Int = 31,
        k: Double = 0.18,
        dynamicRange: Double = 128.0,
    ): Pair<Mat, Mat> {
        val source = Mat()
        luminance.convertTo(source, CvType.CV_32F)
        val (mean, stddev) = computeLocalMeanStd(luminance, windowSize)

        val normalizedStddev = Mat()
        Core.multiply(stddev, Scalar.all(1.0 / dynamicRange), normalizedStddev)
        Core.add(normalizedStddev, Scalar.all(-1.0), normalizedStddev)
        Core.multiply(normalizedStddev, Scalar.all(k), normalizedStddev)
        Core.add(normalizedStddev, Scalar.all(1.0), normalizedStddev)

        val threshold = Mat()
        Core.multiply(mean, normalizedStddev, threshold)

        val delta = Mat()
        Core.subtract(mean, source, delta)

        val candidate = Mat()
        Core.compare(source, threshold, candidate, Core.CMP_LE)

        val stdSoft = Mat()
        Core.multiply(stddev, Scalar.all(0.22), stdSoft)
        val softFloor = Mat(stddev.size(), CvType.CV_32F, Scalar.all(10.0))
        val softThreshold = Mat()
        Core.max(stdSoft, softFloor, softThreshold)

        val stdStrong = Mat()
        Core.multiply(stddev, Scalar.all(0.40), stdStrong)
        val strongFloor = Mat(stddev.size(), CvType.CV_32F, Scalar.all(22.0))
        val strongThreshold = Mat()
        Core.max(stdStrong, strongFloor, strongThreshold)

        val softDeltaMask = Mat()
        Core.compare(delta, softThreshold, softDeltaMask, Core.CMP_GE)
        val strongDeltaMask = Mat()
        Core.compare(delta, strongThreshold, strongDeltaMask, Core.CMP_GE)

        val soft = Mat()
        val strong = Mat()
        Core.bitwise_and(candidate, softDeltaMask, soft)
        Core.bitwise_and(candidate, strongDeltaMask, strong)

        source.release()
        mean.release()
        stddev.release()
        normalizedStddev.release()
        threshold.release()
        delta.release()
        candidate.release()
        stdSoft.release()
        softFloor.release()
        softThreshold.release()
        stdStrong.release()
        strongFloor.release()
        strongThreshold.release()
        softDeltaMask.release()
        strongDeltaMask.release()

        return soft to strong
    }

    private fun estimateBwToneCount(luminance: Mat): Int {
        val q10 = percentileOfMat(luminance, 0.10)
        val q50 = percentileOfMat(luminance, 0.50)
        val lowTail = q50 - q10

        val values = ByteArray((luminance.total() * luminance.channels()).toInt())
        luminance.get(0, 0, values)
        var midCount = 0
        for (value in values) {
            val intValue = value.toInt() and 0xFF
            if (intValue in 96 until 220) midCount++
        }
        val midRatio = midCount.toDouble() / values.size.toDouble()

        return when {
            q10 >= 232.0 && lowTail < 12.0 -> 2
            q10 >= 185.0 && lowTail < 60.0 && midRatio < 0.12 -> 3
            else -> 4
        }
    }

    private fun buildQuantizationSample(luminance: Mat): FloatArray {
        val values = ByteArray((luminance.total() * luminance.channels()).toInt())
        luminance.get(0, 0, values)

        val darker = ArrayList<Int>()
        val brighter = ArrayList<Int>()
        for (value in values) {
            val intValue = value.toInt() and 0xFF
            if (intValue < 224) darker.add(intValue) else brighter.add(intValue)
        }

        val maxBrighter = minOf(brighter.size, maxOf(darker.size * 2, 12000))
        val sampledBrighter = if (brighter.size > maxBrighter && maxBrighter > 0) {
            val sorted = brighter.sorted()
            IntArray(maxBrighter) { index ->
                val sampleIndex = ((sorted.size - 1).toDouble() * index / (maxBrighter - 1).coerceAtLeast(1)).toInt()
                sorted[sampleIndex]
            }.toList()
        } else {
            brighter
        }

        val merged = if (darker.isNotEmpty()) darker + sampledBrighter else values.map { it.toInt() and 0xFF }
        val capped = if (merged.size > 50000) {
            val sorted = merged.sorted()
            IntArray(50000) { index ->
                val sampleIndex = ((sorted.size - 1).toDouble() * index / 49999.0).toInt()
                sorted[sampleIndex]
            }.toList()
        } else {
            merged
        }

        return FloatArray(capped.size) { index -> capped[index].toFloat() }
    }

    private fun fitQuantizationLevels(sample: FloatArray, toneCount: Int): IntArray {
        if (toneCount == 2) {
            val sampleMat = Mat(sample.size, 1, CvType.CV_8U)
            val sampleBytes = ByteArray(sample.size) { index -> sample[index].toInt().toByte() }
            sampleMat.put(0, 0, sampleBytes)
            val tmp = Mat()
            val threshold = Imgproc.threshold(sampleMat, tmp, 0.0, 255.0, Imgproc.THRESH_BINARY + Imgproc.THRESH_OTSU)
            val darkLevel = threshold.times(0.30).toInt().coerceIn(16, 48)
            sampleMat.release()
            tmp.release()
            return intArrayOf(darkLevel, 244)
        }

        val sampleMat = Mat(sample.size, 1, CvType.CV_32F)
        sampleMat.put(0, 0, sample)
        val labels = Mat()
        val centers = Mat()
        val criteria = TermCriteria(TermCriteria.EPS + TermCriteria.MAX_ITER, 32, 0.2)
        Core.kmeans(sampleMat, toneCount, labels, criteria, 4, Core.KMEANS_PP_CENTERS, centers)

        val ordered = IntArray(toneCount) { index -> centers.get(index, 0)[0].toInt().coerceIn(0, 255) }.sortedArray()
        if (toneCount == 3) {
            ordered[0] = ordered[0].coerceIn(16, 52)
            ordered[1] = ordered[1].coerceIn(112, 188)
            ordered[2] = maxOf(236, ordered[2])
        } else {
            ordered[0] = ordered[0].coerceIn(16, 56)
            ordered[1] = ordered[1].coerceIn(72, 132)
            ordered[2] = ordered[2].coerceIn(136, 196)
            ordered[3] = maxOf(236, ordered[3])
        }

        for (index in 1 until ordered.size) {
            if (ordered[index] <= ordered[index - 1]) {
                ordered[index] = minOf(244, ordered[index - 1] + 8)
            }
        }

        sampleMat.release()
        labels.release()
        centers.release()

        return ordered
    }

    private fun quantizeWithLevels(luminance: Mat, levels: IntArray): Mat {
        val thresholds = IntArray(levels.size - 1) { index -> ((levels[index] + levels[index + 1]) / 2.0).toInt() }
        val values = ByteArray((luminance.total() * luminance.channels()).toInt())
        luminance.get(0, 0, values)
        val quantized = ByteArray(values.size)

        for (index in values.indices) {
            val value = values[index].toInt() and 0xFF
            var levelIndex = 0
            while (levelIndex < thresholds.size && value >= thresholds[levelIndex]) {
                levelIndex++
            }
            quantized[index] = levels[levelIndex].toByte()
        }

        val result = Mat(luminance.size(), CvType.CV_8U)
        result.put(0, 0, quantized)
        return result
    }

    private fun applyPaperFloor(
        quantized: Mat,
        paperMask: Mat,
        levels: IntArray,
        toneCount: Int,
    ) {
        val quantizedBytes = ByteArray((quantized.total() * quantized.channels()).toInt())
        val maskBytes = ByteArray((paperMask.total() * paperMask.channels()).toInt())
        quantized.get(0, 0, quantizedBytes)
        paperMask.get(0, 0, maskBytes)

        val paperFloor = if (toneCount >= 3) levels[levels.size - 2] else levels.last()
        for (index in quantizedBytes.indices) {
            if ((maskBytes[index].toInt() and 0xFF) == 0) continue
            val current = quantizedBytes[index].toInt() and 0xFF
            val updated = if (toneCount >= 3) maxOf(current, paperFloor) else paperFloor
            quantizedBytes[index] = updated.toByte()
        }
        quantized.put(0, 0, quantizedBytes)
    }

    private fun maskedMinScaled(
        base: Mat,
        reference: Mat,
        mask: Mat,
        scale: Double,
    ): Mat {
        val baseBytes = ByteArray((base.total() * base.channels()).toInt())
        val refBytes = ByteArray((reference.total() * reference.channels()).toInt())
        val maskBytes = ByteArray((mask.total() * mask.channels()).toInt())
        base.get(0, 0, baseBytes)
        reference.get(0, 0, refBytes)
        mask.get(0, 0, maskBytes)

        val outBytes = baseBytes.copyOf()
        for (index in outBytes.indices) {
            if ((maskBytes[index].toInt() and 0xFF) == 0) continue
            val baseValue = outBytes[index].toInt() and 0xFF
            val scaledRef = ((refBytes[index].toInt() and 0xFF) * scale).toInt().coerceIn(0, 255)
            outBytes[index] = minOf(baseValue, scaledRef).toByte()
        }

        val output = Mat(base.size(), CvType.CV_8U)
        output.put(0, 0, outBytes)
        return output
    }

    private fun boostWhiteboardAccentColors(bgr: Mat, accentMask: Mat): Mat {
        val hsv = Mat()
        Imgproc.cvtColor(bgr, hsv, Imgproc.COLOR_BGR2HSV)

        val hsvBytes = ByteArray((hsv.total() * hsv.channels()).toInt())
        val maskBytes = ByteArray((accentMask.total() * accentMask.channels()).toInt())
        hsv.get(0, 0, hsvBytes)
        accentMask.get(0, 0, maskBytes)

        for (index in maskBytes.indices) {
            if ((maskBytes[index].toInt() and 0xFF) == 0) continue
            val base = index * 3
            val saturation = hsvBytes[base + 1].toInt() and 0xFF
            val value = hsvBytes[base + 2].toInt() and 0xFF
            hsvBytes[base + 1] = minOf((saturation * 1.38 + 8.0).toInt(), 255).toByte()
            hsvBytes[base + 2] = minOf((value * 1.05 + 2.0).toInt(), 255).toByte()
        }

        hsv.put(0, 0, hsvBytes)
        val boosted = Mat()
        Imgproc.cvtColor(hsv, boosted, Imgproc.COLOR_HSV2BGR)
        hsv.release()
        return boosted
    }

    private fun bitmapFromRgb(rgb: Mat, width: Int, height: Int): Bitmap {
        val rgba = Mat()
        Imgproc.cvtColor(rgb, rgba, Imgproc.COLOR_RGB2RGBA)
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(rgba, output)
        rgba.release()
        return output
    }

    companion object {
        fun brightnessMatrix(value: Float): ColorMatrix {
            val offset = 255f * (value - 1f)
            return ColorMatrix(floatArrayOf(
                1f, 0f, 0f, 0f, offset,
                0f, 1f, 0f, 0f, offset,
                0f, 0f, 1f, 0f, offset,
                0f, 0f, 0f, 1f, 0f,
            ))
        }

        fun contrastMatrix(value: Float): ColorMatrix {
            val offset = 128f * (1f - value)
            return ColorMatrix(floatArrayOf(
                value, 0f, 0f, 0f, offset,
                0f, value, 0f, 0f, offset,
                0f, 0f, value, 0f, offset,
                0f, 0f, 0f, 1f, 0f,
            ))
        }

        fun grayscaleMatrix(): ColorMatrix =
            ColorMatrix().apply { setSaturation(0f) }

        fun saturationMatrix(value: Float): ColorMatrix =
            ColorMatrix().apply { setSaturation(value) }
    }
}
