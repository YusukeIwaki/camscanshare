package io.github.yusukeiwaki.camscanshare.data.image

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.Matrix
import android.graphics.Paint
import android.os.SystemClock
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
import kotlin.math.roundToInt

@Singleton
class ImageProcessor @Inject constructor(
    private val debugSink: ImageProcessingDebugSink,
) {

    constructor() : this(ImageProcessingDebugSink.noOp())

    init {
        OpenCVLoader.initLocal()
    }

    private data class DocumentAnalysis(
        val flattenedL: Mat,
        val denoisedL: Mat,
        val paperMask: Mat,
        val paperCleanMask: Mat,
        val accentMask: Mat,
        val strongStructureMask: Mat,
        val neutralizedA: Mat,
        val neutralizedB: Mat,
        val paperColorMask: Mat,
        val colorRichness: Double,
    ) {
        fun release() {
            flattenedL.release()
            denoisedL.release()
            paperMask.release()
            paperCleanMask.release()
            accentMask.release()
            strongStructureMask.release()
            neutralizedA.release()
            neutralizedB.release()
            paperColorMask.release()
        }
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
     * Apply a filter to a bitmap. Document filters use OpenCV pipelines
     * matching the docs evaluation logic; lightweight color presets continue
     * to use ColorMatrix.
     */
    fun applyFilter(source: Bitmap, filterKey: String): Bitmap {
        val session = debugSink.startSession(
            category = "filter",
            label = filterKey,
            metadata = mapOf(
                "filterKey" to filterKey,
                "inputWidth" to source.width.toString(),
                "inputHeight" to source.height.toString(),
            ),
        )
        val started = SystemClock.elapsedRealtimeNanos()
        debugSink.writeBitmap(session, "input", source)

        val output = when (filterKey) {
            "enhance" -> applyEnhanceFilter(source, session)
            "eco" -> applyEcoFilter(source, session)
            "shadowless" -> applyShadowlessFilter(source, session)
            "magic" -> applyMagicFilter(source, session)
            "bw" -> applyDocumentBwFilter(source, session)
            "magic_pro" -> applyMagicProFilter(source, session)
            "whiteboard" -> applyWhiteboardFilter(source, session)
            else -> {
                val colorMatrix = getColorMatrix(filterKey)
                if (colorMatrix == null) {
                    source
                } else {
                    val result = Bitmap.createBitmap(source.width, source.height, Bitmap.Config.ARGB_8888)
                    val canvas = Canvas(result)
                    val paint = Paint().apply {
                        colorFilter = ColorMatrixColorFilter(colorMatrix)
                    }
                    canvas.drawBitmap(source, 0f, 0f, paint)
                    result
                }
            }
        }

        debugSink.writeBitmap(session, "output", output)
        debugSink.recordTimingSince(
            session = session,
            stage = "filter.total",
            startElapsedRealtimeNanos = started,
            metadata = mapOf(
                "outputWidth" to output.width.toString(),
                "outputHeight" to output.height.toString(),
            ),
        )
        return output
    }

    /**
     * Get the ColorMatrix for a given filter key. Returns null for filters
     * handled by the OpenCV pipelines.
     */
    fun getColorMatrix(filterKey: String): ColorMatrix? = when (filterKey) {
        "original" -> null
        "enhance" -> null
        "eco" -> null
        "shadowless" -> null
        "magic" -> null
        "sharpen" -> contrastMatrix(1.4f).apply { postConcat(brightnessMatrix(1.05f)) }
        "bw" -> null
        "magic_pro" -> null
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
     * 4. Whiten only truly neutral paper while preserving color-rich regions
     */
    private fun applyMagicFilter(
        source: Bitmap,
        session: ImageProcessingDebugSession?,
    ): Bitmap {
        val mat = Mat()
        Utils.bitmapToMat(source, mat)
        val rgb = Mat()
        Imgproc.cvtColor(mat, rgb, Imgproc.COLOR_RGBA2RGB)
        debugSink.writeMat(session, "magic_rgb_input", rgb, DebugMatColor.RGB)

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
        debugSink.writeMat(session, "magic_luminance", luminance)
        debugSink.writeMat(session, "magic_illumination", illumination)
        debugSink.writeMat(session, "magic_flattened_l", flattenedL)
        debugSink.writeMat(session, "magic_stretched_l", stretchedL)
        debugSink.writeMat(session, "magic_denoised_l", denoisedL)

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
        debugSink.writeMat(session, "magic_paper_mask", paperMask)
        debugSink.writeMat(session, "magic_structure_mask", structureMask)
        debugSink.writeMat(session, "magic_accent_mask", accentMask)

        val paperBias = estimatePaperBias(aChannel, bChannel, paperMask)
        val neutralizedA = shiftChannel(aChannel, paperBias.first - 128.0)
        val neutralizedB = shiftChannel(bChannel, paperBias.second - 128.0)

        val neutralReferenceLab = Mat()
        Core.merge(listOf(denoisedL, neutralizedA, neutralizedB), neutralReferenceLab)
        val neutralReferenceBgr = Mat()
        Imgproc.cvtColor(neutralReferenceLab, neutralReferenceBgr, Imgproc.COLOR_Lab2BGR)
        val referenceSaturation = saturationChannelFromBgr(neutralReferenceBgr)
        val visibleMask = buildVisibleMask(denoisedL)
        val colorRichness = estimateColorRichness(referenceSaturation, visibleMask)
        val paperColorMask = buildPaperColorMask(
            referenceSaturation,
            denoisedL,
            paperMask,
            accentMask,
            colorRichness,
        )
        debugSink.writeMat(session, "magic_reference_saturation", referenceSaturation)
        debugSink.writeMat(session, "magic_paper_color_mask", paperColorMask)
        debugSink.writeText(
            session,
            "magic-analysis.json",
            "{\"colorRichness\":\"${colorRichness}\"}",
        )

        val mutedFactor = 0.18 + 0.18 * colorRichness
        val paperColorFactor = 0.42 + 0.30 * colorRichness
        val accentFactor = minOf(1.0, 0.86 + 0.10 * colorRichness)

        val mutedA = compressChroma(neutralizedA, mutedFactor)
        val mutedB = compressChroma(neutralizedB, mutedFactor)
        val paperColorA = compressChroma(neutralizedA, paperColorFactor)
        val paperColorB = compressChroma(neutralizedB, paperColorFactor)
        val accentA = compressChroma(neutralizedA, accentFactor)
        val accentB = compressChroma(neutralizedB, accentFactor)

        val outputL = blendTowardValue(denoisedL, paperMask, 244.0, 0.34)
        val blendedL = Mat()
        Core.addWeighted(outputL, 0.58, denoisedL, 0.42, 0.0, blendedL)
        val preserveLMix = 0.24 + 0.18 * colorRichness
        val preservedL = blendMaskedTowardReference(blendedL, denoisedL, paperColorMask, preserveLMix)
        debugSink.writeMat(session, "magic_output_l", preservedL)
        val outputA = Mat(mutedA.size(), mutedA.type())
        val outputB = Mat(mutedB.size(), mutedB.type())
        mutedA.copyTo(outputA)
        mutedB.copyTo(outputB)
        paperColorA.copyTo(outputA, paperColorMask)
        paperColorB.copyTo(outputB, paperColorMask)
        accentA.copyTo(outputA, accentMask)
        accentB.copyTo(outputB, accentMask)
        val nonPaperColorMask = invertMask(paperColorMask)
        val nonAccentMask = invertMask(accentMask)
        val paperNeutralizeMask = Mat()
        Core.bitwise_and(paperMask, nonPaperColorMask, paperNeutralizeMask)
        Core.bitwise_and(paperNeutralizeMask, nonAccentMask, paperNeutralizeMask)
        outputA.setTo(Scalar.all(128.0), paperNeutralizeMask)
        outputB.setTo(Scalar.all(128.0), paperNeutralizeMask)

        val resultLab = Mat()
        Core.merge(listOf(preservedL, outputA, outputB), resultLab)

        val resultBgr = Mat()
        Imgproc.cvtColor(resultLab, resultBgr, Imgproc.COLOR_Lab2BGR)
        val restoredBgr = restoreContentSaturation(
            resultBgr,
            denoisedL,
            neutralizedA,
            neutralizedB,
            paperMask,
            accentMask,
            paperColorMask,
        )

        val resultRgba = Mat()
        Imgproc.cvtColor(restoredBgr, resultRgba, Imgproc.COLOR_BGR2RGBA)

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
        neutralReferenceLab.release()
        neutralReferenceBgr.release()
        referenceSaturation.release()
        visibleMask.release()
        paperColorMask.release()
        mutedA.release()
        mutedB.release()
        paperColorA.release()
        paperColorB.release()
        accentA.release()
        accentB.release()
        outputL.release()
        blendedL.release()
        preservedL.release()
        outputA.release()
        outputB.release()
        nonPaperColorMask.release()
        nonAccentMask.release()
        paperNeutralizeMask.release()
        resultLab.release()
        resultBgr.release()
        restoredBgr.release()
        resultRgba.release()

        return output
    }

    private fun applyDocumentBwFilter(
        source: Bitmap,
        session: ImageProcessingDebugSession?,
    ): Bitmap {
        val rgba = Mat()
        Utils.bitmapToMat(source, rgba)
        val rgb = Mat()
        Imgproc.cvtColor(rgba, rgb, Imgproc.COLOR_RGBA2RGB)
        debugSink.writeMat(session, "bw_rgb_input", rgb, DebugMatColor.RGB)

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
        val luminance = Mat()
        Core.extractChannel(lab, luminance, 0)
        debugSink.writeMat(session, "bw_working_rgb", workingRgb, DebugMatColor.RGB)
        debugSink.writeMat(session, "bw_luminance", luminance)

        val illumination = estimateIllumination(luminance)
        val flattenedL = flatFieldCorrect(luminance, illumination)
        val stretchedL = autoStretchLuminance(flattenedL)
        val denoisedL = Mat()
        Imgproc.medianBlur(stretchedL, denoisedL, 3)
        debugSink.writeMat(session, "bw_illumination", illumination)
        debugSink.writeMat(session, "bw_flattened_l", flattenedL)
        debugSink.writeMat(session, "bw_stretched_l", stretchedL)
        debugSink.writeMat(session, "bw_denoised_l", denoisedL)
        val denoisedFloat = Mat()
        denoisedL.convertTo(denoisedFloat, CvType.CV_32F)

        val localMean = Mat()
        Imgproc.GaussianBlur(denoisedFloat, localMean, Size(71.0, 71.0), 0.0)
        debugSink.writeMat(session, "bw_local_mean", localMean)

        val denominator = Mat()
        Core.add(localMean, Scalar.all(1.0), denominator)

        val normalizedFloat = Mat()
        Core.divide(denoisedFloat, denominator, normalizedFloat, 255.0)

        val normalized = Mat()
        normalizedFloat.convertTo(normalized, CvType.CV_8U)
        debugSink.writeMat(session, "bw_normalized", normalized)

        val binary = Mat()
        Imgproc.threshold(normalized, binary, 228.0, 255.0, Imgproc.THRESH_BINARY)

        val blackMask = Mat()
        Core.bitwise_not(binary, blackMask)

        val labels = Mat()
        val stats = Mat()
        val centroids = Mat()
        val numLabels = Imgproc.connectedComponentsWithStats(
            blackMask,
            labels,
            stats,
            centroids,
            8,
            CvType.CV_32S,
        )

        val componentMask = Mat()
        for (label in 1 until numLabels) {
            val area = stats.get(label, Imgproc.CC_STAT_AREA)?.getOrNull(0)?.toInt() ?: continue
            if (area >= 8) continue
            Core.compare(labels, Scalar.all(label.toDouble()), componentMask, Core.CMP_EQ)
            binary.setTo(Scalar.all(255.0), componentMask)
        }
        debugSink.writeMat(session, "bw_binary_cleaned", binary)
        debugSink.writeMat(session, "bw_black_mask", blackMask)

        val bwRgb = Mat()
        Core.merge(listOf(binary, binary, binary), bwRgb)

        val outputRgb = Mat()
        if (upscale) {
            Imgproc.resize(bwRgb, outputRgb, Size(originalWidth.toDouble(), originalHeight.toDouble()), 0.0, 0.0, Imgproc.INTER_AREA)
        } else {
            bwRgb.copyTo(outputRgb)
        }

        val output = bitmapFromRgb(outputRgb, source.width, source.height)
        debugSink.writeMat(session, "bw_output_rgb", outputRgb, DebugMatColor.RGB)

        rgba.release()
        rgb.release()
        workingRgb.release()
        lab.release()
        luminance.release()
        illumination.release()
        flattenedL.release()
        stretchedL.release()
        denoisedL.release()
        denoisedFloat.release()
        localMean.release()
        denominator.release()
        normalizedFloat.release()
        normalized.release()
        binary.release()
        blackMask.release()
        labels.release()
        stats.release()
        centroids.release()
        componentMask.release()
        bwRgb.release()
        outputRgb.release()

        return output
    }

    private fun applyEnhanceFilter(
        source: Bitmap,
        session: ImageProcessingDebugSession?,
    ): Bitmap {
        val rgb = bitmapToRgb(source)
        val analysis = prepareDocumentAnalysis(rgb, session)

        val contrastedL = applyChannelContrast(analysis.denoisedL, 1.18)
        val baseL = Mat()
        Core.addWeighted(analysis.denoisedL, 0.74, contrastedL, 0.26, 0.0, baseL)
        val outputL0 = blendTowardValue(baseL, analysis.paperCleanMask, 244.0, 0.24)
        val outputL1 = Mat()
        Core.addWeighted(outputL0, 0.72, baseL, 0.28, 0.0, outputL1)
        val outputL = blendMaskedTowardReference(outputL1, analysis.denoisedL, analysis.paperColorMask, 0.34)
        debugSink.writeMat(session, "enhance_contrasted_l", contrastedL)
        debugSink.writeMat(session, "enhance_output_l", outputL)

        val (outputA, outputB) = buildDocumentChromaOutputs(
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.paperColorMask,
            analysis.accentMask,
            mutedFactor = 0.56,
            paperColorFactor = 0.84,
            accentFactor = 1.0,
        )

        val finalLab = Mat()
        Core.merge(listOf(outputL, outputA, outputB), finalLab)
        val finalBgr = Mat()
        Imgproc.cvtColor(finalLab, finalBgr, Imgproc.COLOR_Lab2BGR)
        val restoredBgr = restoreContentSaturation(
            finalBgr,
            analysis.denoisedL,
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.accentMask,
            analysis.paperColorMask,
        )
        val finalRgb = Mat()
        Imgproc.cvtColor(restoredBgr, finalRgb, Imgproc.COLOR_BGR2RGB)
        debugSink.writeMat(session, "enhance_final_rgb", finalRgb, DebugMatColor.RGB)
        val output = bitmapFromRgb(finalRgb, source.width, source.height)

        rgb.release()
        analysis.release()
        contrastedL.release()
        baseL.release()
        outputL0.release()
        outputL1.release()
        outputL.release()
        outputA.release()
        outputB.release()
        finalLab.release()
        finalBgr.release()
        restoredBgr.release()
        finalRgb.release()

        return output
    }

    private fun applyEcoFilter(
        source: Bitmap,
        session: ImageProcessingDebugSession?,
    ): Bitmap {
        val rgb = bitmapToRgb(source)
        val analysis = prepareDocumentAnalysis(rgb, session)

        val relaxedPaperMask = buildRelaxedPaperMask(
            analysis.flattenedL,
            analysis.neutralizedA,
            analysis.neutralizedB,
        )
        val preserveStructureMask = filterStructureForPreservation(
            analysis.strongStructureMask,
            analysis.denoisedL.width(),
            analysis.denoisedL.height(),
        )
        val preserveMask = Mat()
        Core.bitwise_or(preserveStructureMask, analysis.accentMask, preserveMask)
        val preserveKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        val dilatedPreserveMask = Mat()
        Imgproc.dilate(preserveMask, dilatedPreserveMask, preserveKernel, org.opencv.core.Point(-1.0, -1.0), 1)
        val invertedDilatedPreserveMask = invertMask(dilatedPreserveMask)
        val paperToneMask = Mat()
        Core.bitwise_and(relaxedPaperMask, invertedDilatedPreserveMask, paperToneMask)
        debugSink.writeMat(session, "eco_relaxed_paper_mask", relaxedPaperMask)
        debugSink.writeMat(session, "eco_preserve_mask", preserveMask)
        debugSink.writeMat(session, "eco_paper_tone_mask", paperToneMask)

        val baseL0 = Mat()
        Core.addWeighted(analysis.denoisedL, 0.84, analysis.flattenedL, 0.16, 0.0, baseL0)
        val baseL = Mat()
        Imgproc.medianBlur(baseL0, baseL, 3)
        val liftedL = liftShadowedPaper(baseL, paperToneMask, strength = 0.36, sigma = 8.5)
        val outputL0 = blendTowardValue(liftedL, paperToneMask, 249.0, 0.54)
        val outputL1 = Mat()
        Core.addWeighted(outputL0, 0.84, liftedL, 0.16, 0.0, outputL1)
        val softenedL = softenPaperTexture(
            outputL1,
            relaxedPaperMask,
            preserveMask,
            blurSigma = 2.0,
            strength = 0.22,
        )
        val outputL = blendMaskedTowardReference(softenedL, analysis.denoisedL, analysis.paperColorMask, 0.30)
        debugSink.writeMat(session, "eco_lifted_l", liftedL)
        debugSink.writeMat(session, "eco_softened_l", softenedL)
        debugSink.writeMat(session, "eco_output_l", outputL)

        val colorRichness = analysis.colorRichness
        val (outputA, outputB) = buildDocumentChromaOutputs(
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.paperColorMask,
            analysis.accentMask,
            mutedFactor = 0.54 + 0.08 * colorRichness,
            paperColorFactor = 0.82 + 0.10 * colorRichness,
            accentFactor = minOf(1.0, 0.98 + 0.02 * colorRichness),
        )

        val finalLab = Mat()
        Core.merge(listOf(outputL, outputA, outputB), finalLab)
        val finalBgr = Mat()
        Imgproc.cvtColor(finalLab, finalBgr, Imgproc.COLOR_Lab2BGR)
        val restoredBgr = restoreContentSaturation(
            finalBgr,
            analysis.denoisedL,
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.accentMask,
            analysis.paperColorMask,
        )
        val finalRgb = Mat()
        Imgproc.cvtColor(restoredBgr, finalRgb, Imgproc.COLOR_BGR2RGB)
        debugSink.writeMat(session, "eco_final_rgb", finalRgb, DebugMatColor.RGB)
        val output = bitmapFromRgb(finalRgb, source.width, source.height)

        rgb.release()
        analysis.release()
        relaxedPaperMask.release()
        preserveStructureMask.release()
        preserveMask.release()
        preserveKernel.release()
        dilatedPreserveMask.release()
        invertedDilatedPreserveMask.release()
        paperToneMask.release()
        baseL0.release()
        baseL.release()
        liftedL.release()
        outputL0.release()
        outputL1.release()
        softenedL.release()
        outputL.release()
        outputA.release()
        outputB.release()
        finalLab.release()
        finalBgr.release()
        restoredBgr.release()
        finalRgb.release()

        return output
    }

    private fun applyMagicProFilter(
        source: Bitmap,
        session: ImageProcessingDebugSession?,
    ): Bitmap {
        val rgb = bitmapToRgb(source)
        val analysis = prepareDocumentAnalysis(rgb, session)
        val colorRichness = analysis.colorRichness

        val relaxedPaperMask = buildRelaxedPaperMask(
            analysis.flattenedL,
            analysis.neutralizedA,
            analysis.neutralizedB,
        )
        val preserveStructureMask = filterStructureForPreservation(
            analysis.strongStructureMask,
            analysis.denoisedL.width(),
            analysis.denoisedL.height(),
        )
        val preserveKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        val dilatedPreserveStructureMask = Mat()
        Imgproc.dilate(
            preserveStructureMask,
            dilatedPreserveStructureMask,
            preserveKernel,
            org.opencv.core.Point(-1.0, -1.0),
            1,
        )
        val preserveMask = Mat()
        Core.bitwise_or(dilatedPreserveStructureMask, analysis.accentMask, preserveMask)
        val surfaceMask = Mat()
        Core.bitwise_or(relaxedPaperMask, analysis.paperColorMask, surfaceMask)
        val invertedPreserveMask = invertMask(preserveMask)
        val surfaceToneMask = Mat()
        Core.bitwise_and(surfaceMask, invertedPreserveMask, surfaceToneMask)
        debugSink.writeMat(session, "magic_pro_relaxed_paper_mask", relaxedPaperMask)
        debugSink.writeMat(session, "magic_pro_preserve_mask", preserveMask)
        debugSink.writeMat(session, "magic_pro_surface_mask", surfaceMask)
        debugSink.writeMat(session, "magic_pro_surface_tone_mask", surfaceToneMask)

        val flatMix = 0.54 + 0.18 * colorRichness
        val baseL0 = Mat()
        Core.addWeighted(
            analysis.denoisedL,
            maxOf(0.0, 1.0 - flatMix),
            analysis.flattenedL,
            minOf(1.0, flatMix),
            0.0,
            baseL0,
        )
        val contrastedBaseL = applyChannelContrast(baseL0, 1.18)
        val baseL = Mat()
        Core.addWeighted(baseL0, 0.72, contrastedBaseL, 0.28, 0.0, baseL)
        val liftedL = liftShadowedPaper(
            baseL,
            surfaceToneMask,
            strength = 0.74 + 0.12 * colorRichness,
            sigma = 11.0,
        )
        val outputL0 = blendTowardValue(liftedL, analysis.paperCleanMask, 249.0, 0.58)
        val coloredToneMask = Mat()
        Core.bitwise_and(surfaceToneMask, analysis.paperColorMask, coloredToneMask)
        val outputL1 = blendTowardValue(outputL0, coloredToneMask, 236.0, 0.18 + 0.14 * colorRichness)
        val outputL2 = Mat()
        Core.addWeighted(outputL1, 0.80, liftedL, 0.20, 0.0, outputL2)
        val softenedL = softenPaperTexture(
            outputL2,
            surfaceMask,
            preserveMask,
            blurSigma = 2.6,
            strength = 0.28 + 0.08 * colorRichness,
        )
        val outputL = blendMaskedTowardReference(softenedL, liftedL, analysis.paperColorMask, 0.12)
        debugSink.writeMat(session, "magic_pro_base_l", baseL)
        debugSink.writeMat(session, "magic_pro_lifted_l", liftedL)
        debugSink.writeMat(session, "magic_pro_softened_l", softenedL)
        debugSink.writeMat(session, "magic_pro_output_l", outputL)

        val (outputA, outputB) = buildDocumentChromaOutputs(
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.paperColorMask,
            analysis.accentMask,
            mutedFactor = 0.16 + 0.08 * colorRichness,
            paperColorFactor = 0.70 + 0.20 * colorRichness,
            accentFactor = minOf(1.0, 0.98 + 0.02 * colorRichness),
        )
        val finalLab = Mat()
        Core.merge(listOf(outputL, outputA, outputB), finalLab)
        val finalBgr = Mat()
        Imgproc.cvtColor(finalLab, finalBgr, Imgproc.COLOR_Lab2BGR)
        val restoredBgr = restoreContentSaturation(
            finalBgr,
            analysis.denoisedL,
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.accentMask,
            analysis.paperColorMask,
        )
        val boostedBgr = if (colorRichness > 0.18) {
            boostMagicProColors(restoredBgr, analysis.paperColorMask, analysis.accentMask, colorRichness)
        } else {
            restoredBgr.clone()
        }
        val finalRgb = Mat()
        Imgproc.cvtColor(boostedBgr, finalRgb, Imgproc.COLOR_BGR2RGB)
        debugSink.writeMat(session, "magic_pro_final_rgb", finalRgb, DebugMatColor.RGB)
        val output = bitmapFromRgb(finalRgb, source.width, source.height)

        rgb.release()
        analysis.release()
        relaxedPaperMask.release()
        preserveStructureMask.release()
        preserveKernel.release()
        dilatedPreserveStructureMask.release()
        preserveMask.release()
        surfaceMask.release()
        invertedPreserveMask.release()
        surfaceToneMask.release()
        baseL0.release()
        contrastedBaseL.release()
        baseL.release()
        liftedL.release()
        outputL0.release()
        coloredToneMask.release()
        outputL1.release()
        outputL2.release()
        softenedL.release()
        outputL.release()
        outputA.release()
        outputB.release()
        finalLab.release()
        finalBgr.release()
        restoredBgr.release()
        boostedBgr.release()
        finalRgb.release()

        return output
    }

    private fun applyShadowlessFilter(
        source: Bitmap,
        session: ImageProcessingDebugSession?,
    ): Bitmap {
        val rgb = bitmapToRgb(source)
        val analysis = prepareDocumentAnalysis(rgb, session)
        val colorRichness = analysis.colorRichness

        val relaxedPaperMask = buildRelaxedPaperMask(
            analysis.flattenedL,
            analysis.neutralizedA,
            analysis.neutralizedB,
        )
        val surfaceMask = Mat()
        Core.bitwise_or(relaxedPaperMask, analysis.paperColorMask, surfaceMask)
        val probeL = Mat()
        Core.addWeighted(analysis.denoisedL, 0.35, analysis.flattenedL, 0.65, 0.0, probeL)
        val preserveMask = buildShadowlessInkMask(probeL, analysis.strongStructureMask)
        val invertedPreserveMask = invertMask(preserveMask)
        val surfaceToneMask = Mat()
        Core.bitwise_and(surfaceMask, invertedPreserveMask, surfaceToneMask)
        debugSink.writeMat(session, "shadowless_relaxed_paper_mask", relaxedPaperMask)
        debugSink.writeMat(session, "shadowless_preserve_mask", preserveMask)
        debugSink.writeMat(session, "shadowless_surface_mask", surfaceMask)
        debugSink.writeMat(session, "shadowless_surface_tone_mask", surfaceToneMask)

        val flatMix = 0.64 + 0.14 * colorRichness
        val baseL0 = Mat()
        Core.addWeighted(
            analysis.denoisedL,
            maxOf(0.0, 1.0 - flatMix),
            analysis.flattenedL,
            minOf(1.0, flatMix),
            0.0,
            baseL0,
        )
        val contrastedBaseL = applyChannelContrast(baseL0, 1.10)
        val baseL = Mat()
        Core.addWeighted(baseL0, 0.82, contrastedBaseL, 0.18, 0.0, baseL)
        val liftedL = liftShadowedPaper(
            baseL,
            surfaceToneMask,
            strength = 0.88,
            sigma = 15.0,
        )
        val outputL0 = blendTowardValue(liftedL, surfaceToneMask, 253.0, 0.72)
        val outputL1 = if (colorRichness > 0.35) {
            blendMaskedTowardReference(outputL0, liftedL, analysis.paperColorMask, 0.10)
        } else {
            outputL0.clone()
        }
        val softenedL = softenPaperTexture(
            outputL1,
            surfaceToneMask,
            preserveMask,
            blurSigma = 3.2,
            strength = 0.45,
        )
        val outputL = softenedL.clone()
        debugSink.writeMat(session, "shadowless_base_l", baseL)
        debugSink.writeMat(session, "shadowless_lifted_l", liftedL)
        debugSink.writeMat(session, "shadowless_softened_l", softenedL)
        debugSink.writeMat(session, "shadowless_output_l", outputL)

        val (outputA, outputB) = buildDocumentChromaOutputs(
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.paperColorMask,
            analysis.accentMask,
            mutedFactor = 0.12 + 0.06 * colorRichness,
            paperColorFactor = 0.62 + 0.18 * colorRichness,
            accentFactor = minOf(1.0, 0.98 + 0.02 * colorRichness),
        )
        val finalLab = Mat()
        Core.merge(listOf(outputL, outputA, outputB), finalLab)
        val finalBgr = Mat()
        Imgproc.cvtColor(finalLab, finalBgr, Imgproc.COLOR_Lab2BGR)
        val restoredBgr = restoreContentSaturation(
            finalBgr,
            analysis.denoisedL,
            analysis.neutralizedA,
            analysis.neutralizedB,
            analysis.paperMask,
            analysis.accentMask,
            analysis.paperColorMask,
        )
        val finalRgb = Mat()
        Imgproc.cvtColor(restoredBgr, finalRgb, Imgproc.COLOR_BGR2RGB)
        debugSink.writeMat(session, "shadowless_final_rgb", finalRgb, DebugMatColor.RGB)
        val output = bitmapFromRgb(finalRgb, source.width, source.height)

        rgb.release()
        analysis.release()
        relaxedPaperMask.release()
        probeL.release()
        preserveMask.release()
        surfaceMask.release()
        invertedPreserveMask.release()
        surfaceToneMask.release()
        baseL0.release()
        contrastedBaseL.release()
        baseL.release()
        liftedL.release()
        outputL0.release()
        outputL1.release()
        softenedL.release()
        outputL.release()
        outputA.release()
        outputB.release()
        finalLab.release()
        finalBgr.release()
        restoredBgr.release()
        finalRgb.release()

        return output
    }

    private fun applyWhiteboardFilter(
        source: Bitmap,
        session: ImageProcessingDebugSession?,
    ): Bitmap {
        val rgba = Mat()
        Utils.bitmapToMat(source, rgba)
        val rgb = Mat()
        Imgproc.cvtColor(rgba, rgb, Imgproc.COLOR_RGBA2RGB)
        debugSink.writeMat(session, "whiteboard_rgb_input", rgb, DebugMatColor.RGB)

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
        debugSink.writeMat(session, "whiteboard_luminance", luminance)
        debugSink.writeMat(session, "whiteboard_illumination", illumination)
        debugSink.writeMat(session, "whiteboard_flattened_l", flattenedL)
        debugSink.writeMat(session, "whiteboard_stretched_l", stretchedL)
        debugSink.writeMat(session, "whiteboard_denoised_l", denoisedL)

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
        debugSink.writeMat(session, "whiteboard_chroma", chroma)
        debugSink.writeMat(session, "whiteboard_accent_mask", accentMask)
        debugSink.writeMat(session, "whiteboard_accent_protect_mask", accentProtectMask)

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
        debugSink.writeMat(session, "whiteboard_structure_mask", structureMask)
        debugSink.writeMat(session, "whiteboard_sauvola_strong", sauvolaStrong)

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
        debugSink.writeMat(session, "whiteboard_bright_mask", brightMask)
        debugSink.writeMat(session, "whiteboard_paper_mask", paperMask)

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
        debugSink.writeMat(session, "whiteboard_output_l", outputL)

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
        debugSink.writeMat(session, "whiteboard_final_rgb", boostedRgb, DebugMatColor.RGB)

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

    private fun buildVisibleMask(luminance: Mat): Mat {
        val visibleMask = Mat()
        Imgproc.threshold(luminance, visibleMask, 48.0, 255.0, Imgproc.THRESH_BINARY)
        return visibleMask
    }

    private fun saturationChannelFromBgr(bgr: Mat): Mat {
        val hsv = Mat()
        Imgproc.cvtColor(bgr, hsv, Imgproc.COLOR_BGR2HSV)
        val channels = ArrayList<Mat>(3)
        Core.split(hsv, channels)
        val saturation = channels[1].clone()

        hsv.release()
        channels.forEach { it.release() }

        return saturation
    }

    private fun estimateColorRichness(referenceSaturation: Mat, visibleMask: Mat): Double {
        val saturationBytes = ByteArray((referenceSaturation.total() * referenceSaturation.channels()).toInt())
        val maskBytes = ByteArray((visibleMask.total() * visibleMask.channels()).toInt())
        referenceSaturation.get(0, 0, saturationBytes)
        visibleMask.get(0, 0, maskBytes)

        var visibleCount = 0
        var colorCount = 0
        for (index in saturationBytes.indices) {
            if ((maskBytes[index].toInt() and 0xFF) == 0) continue
            visibleCount++
            if ((saturationBytes[index].toInt() and 0xFF) > 18) {
                colorCount++
            }
        }
        if (visibleCount == 0) return 0.0

        val colorDensity = colorCount.toDouble() / visibleCount.toDouble()
        return ((colorDensity - 0.025) / 0.14).coerceIn(0.0, 1.0)
    }

    private fun buildPaperColorMask(
        referenceSaturation: Mat,
        luminance: Mat,
        paperMask: Mat,
        accentMask: Mat,
        colorRichness: Double,
    ): Mat {
        val saturationMask = Mat()
        Imgproc.threshold(
            referenceSaturation,
            saturationMask,
            22.0 - 8.0 * colorRichness,
            255.0,
            Imgproc.THRESH_BINARY,
        )
        val visibleMask = buildVisibleMask(luminance)
        val mediumColorMask = Mat()
        Core.bitwise_and(saturationMask, visibleMask, mediumColorMask)
        Core.bitwise_and(mediumColorMask, paperMask, mediumColorMask)

        val paperColorMask = Mat()
        Core.bitwise_or(mediumColorMask, accentMask, paperColorMask)
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        Imgproc.morphologyEx(paperColorMask, paperColorMask, Imgproc.MORPH_OPEN, kernel)

        saturationMask.release()
        visibleMask.release()
        mediumColorMask.release()
        kernel.release()

        return paperColorMask
    }

    private fun blendMaskedTowardReference(base: Mat, reference: Mat, mask: Mat, referenceWeight: Double): Mat {
        val baseBytes = ByteArray((base.total() * base.channels()).toInt())
        val referenceBytes = ByteArray((reference.total() * reference.channels()).toInt())
        val maskBytes = ByteArray((mask.total() * mask.channels()).toInt())
        base.get(0, 0, baseBytes)
        reference.get(0, 0, referenceBytes)
        mask.get(0, 0, maskBytes)

        val outputBytes = baseBytes.copyOf()
        for (index in outputBytes.indices) {
            if ((maskBytes[index].toInt() and 0xFF) == 0) continue
            val baseValue = outputBytes[index].toInt() and 0xFF
            val referenceValue = referenceBytes[index].toInt() and 0xFF
            outputBytes[index] = (
                baseValue * (1.0 - referenceWeight) + referenceValue * referenceWeight
            ).toInt().coerceIn(0, 255).toByte()
        }

        val output = Mat(base.size(), CvType.CV_8U)
        output.put(0, 0, outputBytes)
        return output
    }

    private fun restoreContentSaturation(
        finalBgr: Mat,
        luminance: Mat,
        neutralizedA: Mat,
        neutralizedB: Mat,
        paperMask: Mat,
        accentMask: Mat,
        paperColorMask: Mat,
    ): Mat {
        val neutralReferenceLab = Mat()
        Core.merge(listOf(luminance, neutralizedA, neutralizedB), neutralReferenceLab)
        val neutralReferenceBgr = Mat()
        Imgproc.cvtColor(neutralReferenceLab, neutralReferenceBgr, Imgproc.COLOR_Lab2BGR)

        val finalHsv = Mat()
        Imgproc.cvtColor(finalBgr, finalHsv, Imgproc.COLOR_BGR2HSV)
        val referenceHsv = Mat()
        Imgproc.cvtColor(neutralReferenceBgr, referenceHsv, Imgproc.COLOR_BGR2HSV)

        val finalBytes = ByteArray((finalHsv.total() * finalHsv.channels()).toInt())
        val referenceBytes = ByteArray((referenceHsv.total() * referenceHsv.channels()).toInt())
        val luminanceBytes = ByteArray((luminance.total() * luminance.channels()).toInt())
        val paperBytes = ByteArray((paperMask.total() * paperMask.channels()).toInt())
        val accentBytes = ByteArray((accentMask.total() * accentMask.channels()).toInt())
        val paperColorBytes = ByteArray((paperColorMask.total() * paperColorMask.channels()).toInt())
        finalHsv.get(0, 0, finalBytes)
        referenceHsv.get(0, 0, referenceBytes)
        luminance.get(0, 0, luminanceBytes)
        paperMask.get(0, 0, paperBytes)
        accentMask.get(0, 0, accentBytes)
        paperColorMask.get(0, 0, paperColorBytes)

        var visibleCount = 0
        var colorCount = 0
        for (index in luminanceBytes.indices) {
            val luminanceValue = luminanceBytes[index].toInt() and 0xFF
            if (luminanceValue <= 48) continue
            visibleCount++
            val saturation = referenceBytes[index * 3 + 1].toInt() and 0xFF
            if (saturation > 18) {
                colorCount++
            }
        }
        val colorRichness = if (visibleCount == 0) {
            0.0
        } else {
            ((colorCount.toDouble() / visibleCount.toDouble()) - 0.025) / 0.14
        }.coerceIn(0.0, 1.0)

        for (index in luminanceBytes.indices) {
            val luminanceValue = luminanceBytes[index].toInt() and 0xFF
            if (luminanceValue <= 48) continue

            val paperColorValue = paperColorBytes[index].toInt() and 0xFF
            val restorePixel = (paperBytes[index].toInt() and 0xFF) == 0 || paperColorValue > 0
            if (!restorePixel) continue

            val hsvBase = index * 3
            val referenceSaturation = referenceBytes[hsvBase + 1].toInt() and 0xFF
            if (referenceSaturation <= 10) continue

            val preserveWeight = ((referenceSaturation - 10.0) / 34.0).coerceIn(0.0, 1.0)
            var saturationFloor = referenceSaturation * (
                0.40 + 0.24 * preserveWeight + 0.24 * colorRichness
            )
            if ((accentBytes[index].toInt() and 0xFF) > 0) {
                saturationFloor = maxOf(
                    saturationFloor,
                    referenceSaturation * (0.74 + 0.18 * colorRichness),
                )
            }
            if (paperColorValue > 0) {
                saturationFloor = maxOf(
                    saturationFloor,
                    referenceSaturation * (0.50 + 0.18 * colorRichness),
                )
            }

            val currentSaturation = finalBytes[hsvBase + 1].toInt() and 0xFF
            finalBytes[hsvBase + 1] = maxOf(
                currentSaturation,
                saturationFloor.toInt().coerceIn(0, 255),
            ).toByte()
        }

        finalHsv.put(0, 0, finalBytes)
        val restored = Mat()
        Imgproc.cvtColor(finalHsv, restored, Imgproc.COLOR_HSV2BGR)

        neutralReferenceLab.release()
        neutralReferenceBgr.release()
        finalHsv.release()
        referenceHsv.release()

        return restored
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

    private fun bitmapToRgb(source: Bitmap): Mat {
        val rgba = Mat()
        Utils.bitmapToMat(source, rgba)
        val rgb = Mat()
        Imgproc.cvtColor(rgba, rgb, Imgproc.COLOR_RGBA2RGB)
        rgba.release()
        return rgb
    }

    private fun prepareDocumentAnalysis(
        rgb: Mat,
        session: ImageProcessingDebugSession?,
    ): DocumentAnalysis {
        val started = SystemClock.elapsedRealtimeNanos()
        debugSink.writeMat(session, "analysis_rgb_input", rgb, DebugMatColor.RGB)
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
        debugSink.writeMat(session, "analysis_luminance", luminance)
        debugSink.writeMat(session, "analysis_illumination", illumination)
        debugSink.writeMat(session, "analysis_flattened_l", flattenedL)
        debugSink.writeMat(session, "analysis_stretched_l", stretchedL)
        debugSink.writeMat(session, "analysis_denoised_l", denoisedL)

        val structureBase = applyChannelContrast(denoisedL, 1.18)
        val (_, strongStructureBase) = buildSauvolaStructureMasks(
            structureBase,
            windowSize = 35,
            k = 0.16,
            dynamicRange = 128.0,
        )
        val strongStructureExtra = buildStructureMask(structureBase)
        val strongStructureMask = Mat()
        Core.bitwise_or(strongStructureBase, strongStructureExtra, strongStructureMask)
        Imgproc.medianBlur(strongStructureMask, strongStructureMask, 3)
        debugSink.writeMat(session, "analysis_strong_structure_mask", strongStructureMask)

        val paperMask = buildPaperMask(denoisedL, aChannel, bChannel)
        val accentMask = buildAccentMask(denoisedL, aChannel, bChannel)
        val protectKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        val dilatedStrongStructure = Mat()
        Imgproc.dilate(
            strongStructureMask,
            dilatedStrongStructure,
            protectKernel,
            org.opencv.core.Point(-1.0, -1.0),
            1,
        )
        val protectMask = Mat()
        Core.bitwise_or(dilatedStrongStructure, accentMask, protectMask)
        val invertedProtectMask = invertMask(protectMask)
        val paperCleanMask = Mat()
        Core.bitwise_and(paperMask, invertedProtectMask, paperCleanMask)
        val paperCloseKernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(5.0, 5.0))
        Imgproc.morphologyEx(
            paperCleanMask,
            paperCleanMask,
            Imgproc.MORPH_CLOSE,
            paperCloseKernel,
            org.opencv.core.Point(-1.0, -1.0),
            2,
        )
        debugSink.writeMat(session, "analysis_paper_mask", paperMask)
        debugSink.writeMat(session, "analysis_accent_mask", accentMask)
        debugSink.writeMat(session, "analysis_paper_clean_mask", paperCleanMask)

        val paperBias = estimatePaperBias(aChannel, bChannel, paperMask)
        val neutralizedA = shiftChannel(aChannel, paperBias.first - 128.0)
        val neutralizedB = shiftChannel(bChannel, paperBias.second - 128.0)

        val neutralReferenceLab = Mat()
        Core.merge(listOf(denoisedL, neutralizedA, neutralizedB), neutralReferenceLab)
        val neutralReferenceBgr = Mat()
        Imgproc.cvtColor(neutralReferenceLab, neutralReferenceBgr, Imgproc.COLOR_Lab2BGR)
        val referenceSaturation = saturationChannelFromBgr(neutralReferenceBgr)
        val visibleMask = buildVisibleMask(denoisedL)
        val colorRichness = estimateColorRichness(referenceSaturation, visibleMask)
        val paperColorMask = buildPaperColorMask(
            referenceSaturation,
            denoisedL,
            paperMask,
            accentMask,
            colorRichness,
        )
        debugSink.writeMat(session, "analysis_reference_saturation", referenceSaturation)
        debugSink.writeMat(session, "analysis_paper_color_mask", paperColorMask)
        debugSink.writeText(
            session,
            "analysis.json",
            "{\"colorRichness\":\"${colorRichness}\",\"paperBiasA\":\"${paperBias.first}\",\"paperBiasB\":\"${paperBias.second}\"}",
        )
        debugSink.recordTimingSince(session, "filter.prepare_document_analysis", started)

        lab.release()
        luminance.release()
        aChannel.release()
        bChannel.release()
        illumination.release()
        stretchedL.release()
        structureBase.release()
        strongStructureBase.release()
        strongStructureExtra.release()
        protectKernel.release()
        dilatedStrongStructure.release()
        protectMask.release()
        invertedProtectMask.release()
        paperCloseKernel.release()
        neutralReferenceLab.release()
        neutralReferenceBgr.release()
        referenceSaturation.release()
        visibleMask.release()

        return DocumentAnalysis(
            flattenedL = flattenedL,
            denoisedL = denoisedL,
            paperMask = paperMask,
            paperCleanMask = paperCleanMask,
            accentMask = accentMask,
            strongStructureMask = strongStructureMask,
            neutralizedA = neutralizedA,
            neutralizedB = neutralizedB,
            paperColorMask = paperColorMask,
            colorRichness = colorRichness,
        )
    }

    private fun buildDocumentChromaOutputs(
        neutralizedA: Mat,
        neutralizedB: Mat,
        paperMask: Mat,
        paperColorMask: Mat,
        accentMask: Mat,
        mutedFactor: Double,
        paperColorFactor: Double,
        accentFactor: Double,
    ): Pair<Mat, Mat> {
        val mutedA = compressChroma(neutralizedA, mutedFactor)
        val mutedB = compressChroma(neutralizedB, mutedFactor)
        val paperColorA = compressChroma(neutralizedA, paperColorFactor)
        val paperColorB = compressChroma(neutralizedB, paperColorFactor)
        val accentA = compressChroma(neutralizedA, accentFactor)
        val accentB = compressChroma(neutralizedB, accentFactor)

        val outputA = neutralizedA.clone()
        val outputB = neutralizedB.clone()
        val nonPaperColorMask = invertMask(paperColorMask)
        val nonAccentMask = invertMask(accentMask)
        val paperNeutralMask = Mat()
        Core.bitwise_and(paperMask, nonPaperColorMask, paperNeutralMask)
        Core.bitwise_and(paperNeutralMask, nonAccentMask, paperNeutralMask)

        mutedA.copyTo(outputA, paperNeutralMask)
        mutedB.copyTo(outputB, paperNeutralMask)
        paperColorA.copyTo(outputA, paperColorMask)
        paperColorB.copyTo(outputB, paperColorMask)
        accentA.copyTo(outputA, accentMask)
        accentB.copyTo(outputB, accentMask)

        mutedA.release()
        mutedB.release()
        paperColorA.release()
        paperColorB.release()
        accentA.release()
        accentB.release()
        nonPaperColorMask.release()
        nonAccentMask.release()
        paperNeutralMask.release()

        return outputA to outputB
    }

    private fun buildRelaxedPaperMask(luminance: Mat, aChannel: Mat, bChannel: Mat): Mat {
        val chroma = computeChroma(aChannel, bChannel)
        val brightThreshold = maxOf(72.0, percentileOfMat(luminance, 0.08))
        val brightMask = Mat()
        Imgproc.threshold(luminance, brightMask, brightThreshold, 255.0, Imgproc.THRESH_BINARY)
        val lowChromaMask = Mat()
        Imgproc.threshold(chroma, lowChromaMask, 46.0, 255.0, Imgproc.THRESH_BINARY_INV)
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

    private fun liftShadowedPaper(luminance: Mat, paperMask: Mat, strength: Double, sigma: Double): Mat {
        val luminance32 = Mat()
        luminance.convertTo(luminance32, CvType.CV_32F)
        val smooth = Mat()
        Imgproc.GaussianBlur(luminance32, smooth, Size(0.0, 0.0), sigma)
        val delta = Mat()
        Core.subtract(smooth, luminance32, delta)
        val zero = Mat(delta.size(), delta.type(), Scalar.all(0.0))
        Core.max(delta, zero, delta)
        val deltaCap = Mat(delta.size(), delta.type(), Scalar.all(56.0))
        Core.min(delta, deltaCap, delta)
        val mask32 = Mat()
        paperMask.convertTo(mask32, CvType.CV_32F, strength / 255.0)
        val weightedDelta = Mat()
        Core.multiply(delta, mask32, weightedDelta)
        val lifted32 = Mat()
        Core.add(luminance32, weightedDelta, lifted32)
        val lifted = Mat()
        lifted32.convertTo(lifted, CvType.CV_8U)

        luminance32.release()
        smooth.release()
        delta.release()
        zero.release()
        deltaCap.release()
        mask32.release()
        weightedDelta.release()
        lifted32.release()

        return lifted
    }

    private fun softenPaperTexture(
        luminance: Mat,
        paperMask: Mat,
        preserveMask: Mat,
        blurSigma: Double,
        strength: Double,
    ): Mat {
        val smooth = Mat()
        Imgproc.GaussianBlur(luminance, smooth, Size(0.0, 0.0), blurSigma)

        val outputBytes = ByteArray((luminance.total() * luminance.channels()).toInt())
        val smoothBytes = ByteArray((smooth.total() * smooth.channels()).toInt())
        val paperBytes = ByteArray((paperMask.total() * paperMask.channels()).toInt())
        val preserveBytes = ByteArray((preserveMask.total() * preserveMask.channels()).toInt())
        luminance.get(0, 0, outputBytes)
        smooth.get(0, 0, smoothBytes)
        paperMask.get(0, 0, paperBytes)
        preserveMask.get(0, 0, preserveBytes)

        for (index in outputBytes.indices) {
            if ((paperBytes[index].toInt() and 0xFF) == 0) continue
            if ((preserveBytes[index].toInt() and 0xFF) > 0) continue
            val original = outputBytes[index].toInt() and 0xFF
            val blurred = smoothBytes[index].toInt() and 0xFF
            outputBytes[index] = (
                original * (1.0 - strength) + blurred * strength
            ).roundToInt().coerceIn(0, 255).toByte()
        }

        val softened = Mat(luminance.size(), CvType.CV_8U)
        softened.put(0, 0, outputBytes)
        smooth.release()
        return softened
    }

    private fun filterStructureForPreservation(structureMask: Mat, imageWidth: Int, imageHeight: Int): Mat {
        val filtered = Mat(structureMask.size(), CvType.CV_8U, Scalar.all(0.0))
        val labels = Mat()
        val stats = Mat()
        val centroids = Mat()
        val numLabels = Imgproc.connectedComponentsWithStats(
            structureMask,
            labels,
            stats,
            centroids,
            8,
            CvType.CV_32S,
        )
        val maxLongEdge = maxOf(42, (maxOf(imageWidth, imageHeight) * 0.36).roundToInt())
        val maxShortEdge = maxOf(22, (minOf(imageWidth, imageHeight) * 0.08).roundToInt())

        for (label in 1 until numLabels) {
            val area = stats.get(label, Imgproc.CC_STAT_AREA)?.getOrNull(0)?.toInt() ?: continue
            val width = stats.get(label, Imgproc.CC_STAT_WIDTH)?.getOrNull(0)?.toInt() ?: continue
            val height = stats.get(label, Imgproc.CC_STAT_HEIGHT)?.getOrNull(0)?.toInt() ?: continue
            val fillRatio = area.toDouble() / maxOf(1, width * height).toDouble()
            val longEdge = maxOf(width, height)
            val shortEdge = minOf(width, height)

            if (area > 4800 && fillRatio > 0.12) continue
            if (longEdge > maxLongEdge && fillRatio > 0.08) continue
            if (shortEdge > maxShortEdge && fillRatio > 0.22) continue

            val componentMask = Mat()
            Core.compare(labels, Scalar.all(label.toDouble()), componentMask, Core.CMP_EQ)
            filtered.setTo(Scalar.all(255.0), componentMask)
            componentMask.release()
        }

        labels.release()
        stats.release()
        centroids.release()
        return filtered
    }

    private fun buildShadowlessInkMask(probeL: Mat, strongStructureMask: Mat): Mat {
        val darkThreshold = maxOf(82.0, percentileOfMat(probeL, 0.06))
        val darkMask = Mat()
        Imgproc.threshold(probeL, darkMask, darkThreshold, 255.0, Imgproc.THRESH_BINARY_INV)
        val inkMask = Mat()
        Core.bitwise_and(darkMask, strongStructureMask, inkMask)
        val filtered = filterShadowlessInkComponents(inkMask, probeL.width(), probeL.height())
        val dilated = Mat()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(2.0, 2.0))
        Imgproc.dilate(filtered, dilated, kernel, org.opencv.core.Point(-1.0, -1.0), 1)

        darkMask.release()
        inkMask.release()
        filtered.release()
        kernel.release()
        return dilated
    }

    private fun filterShadowlessInkComponents(inkMask: Mat, imageWidth: Int, imageHeight: Int): Mat {
        val filtered = Mat(inkMask.size(), CvType.CV_8U, Scalar.all(0.0))
        val labels = Mat()
        val stats = Mat()
        val centroids = Mat()
        val numLabels = Imgproc.connectedComponentsWithStats(
            inkMask,
            labels,
            stats,
            centroids,
            8,
            CvType.CV_32S,
        )
        val maxLongSparse = maxOf(70, (maxOf(imageWidth, imageHeight) * 0.11).roundToInt())
        val maxLongEdge = maxOf(150, (maxOf(imageWidth, imageHeight) * 0.26).roundToInt())
        val maxShortSparse = maxOf(24, (minOf(imageWidth, imageHeight) * 0.035).roundToInt())

        for (label in 1 until numLabels) {
            val area = stats.get(label, Imgproc.CC_STAT_AREA)?.getOrNull(0)?.toInt() ?: continue
            val width = stats.get(label, Imgproc.CC_STAT_WIDTH)?.getOrNull(0)?.toInt() ?: continue
            val height = stats.get(label, Imgproc.CC_STAT_HEIGHT)?.getOrNull(0)?.toInt() ?: continue
            if (area < 8) continue

            val fillRatio = area.toDouble() / maxOf(1, width * height).toDouble()
            val longEdge = maxOf(width, height)
            val shortEdge = minOf(width, height)

            if (longEdge > maxLongSparse && fillRatio < 0.22) continue
            if (longEdge > maxLongEdge) continue
            if (shortEdge > maxShortSparse && fillRatio < 0.35) continue

            val componentMask = Mat()
            Core.compare(labels, Scalar.all(label.toDouble()), componentMask, Core.CMP_EQ)
            filtered.setTo(Scalar.all(255.0), componentMask)
            componentMask.release()
        }

        labels.release()
        stats.release()
        centroids.release()
        return filtered
    }

    private fun boostMagicProColors(
        bgr: Mat,
        paperColorMask: Mat,
        accentMask: Mat,
        colorRichness: Double,
    ): Mat {
        val hsv = Mat()
        Imgproc.cvtColor(bgr, hsv, Imgproc.COLOR_BGR2HSV)
        val hsvBytes = ByteArray((hsv.total() * hsv.channels()).toInt())
        val paperColorBytes = ByteArray((paperColorMask.total() * paperColorMask.channels()).toInt())
        val accentBytes = ByteArray((accentMask.total() * accentMask.channels()).toInt())
        hsv.get(0, 0, hsvBytes)
        paperColorMask.get(0, 0, paperColorBytes)
        accentMask.get(0, 0, accentBytes)

        val paperSaturationScale = 1.04 + 0.08 * colorRichness
        val paperValueScale = 1.01 + 0.03 * colorRichness
        val accentSaturationScale = 1.01 + 0.04 * colorRichness

        for (index in paperColorBytes.indices) {
            val base = index * 3
            if ((paperColorBytes[index].toInt() and 0xFF) > 0) {
                val saturation = hsvBytes[base + 1].toInt() and 0xFF
                val value = hsvBytes[base + 2].toInt() and 0xFF
                hsvBytes[base + 1] = minOf((saturation * paperSaturationScale).roundToInt(), 255).toByte()
                hsvBytes[base + 2] = minOf((value * paperValueScale + 1.0).roundToInt(), 255).toByte()
            }
            if ((accentBytes[index].toInt() and 0xFF) > 0) {
                val saturation = hsvBytes[base + 1].toInt() and 0xFF
                hsvBytes[base + 1] = minOf((saturation * accentSaturationScale).roundToInt(), 255).toByte()
            }
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
