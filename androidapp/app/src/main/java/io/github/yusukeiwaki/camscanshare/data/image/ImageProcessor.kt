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
     * Apply a filter to a bitmap. "magic" uses OpenCV flat-field correction;
     * other filters use ColorMatrix.
     */
    fun applyFilter(source: Bitmap, filterKey: String): Bitmap {
        if (filterKey == "magic") return applyMagicFilter(source)

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
     * Get the ColorMatrix for a given filter key. Returns null for "original" and "magic".
     * "magic" is handled separately via OpenCV in applyFilter/applyMagicFilter.
     */
    fun getColorMatrix(filterKey: String): ColorMatrix? = when (filterKey) {
        "original" -> null
        "magic" -> null // handled by OpenCV
        "sharpen" -> contrastMatrix(1.4f).apply { postConcat(brightnessMatrix(1.05f)) }
        "bw" -> grayscaleMatrix().apply { postConcat(contrastMatrix(1.3f)) }
        "whiteboard" -> brightnessMatrix(1.3f).apply {
            postConcat(contrastMatrix(1.6f))
            postConcat(saturationMatrix(0f))
        }
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
