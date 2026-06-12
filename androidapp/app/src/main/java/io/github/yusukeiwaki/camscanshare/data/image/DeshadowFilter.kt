package io.github.yusukeiwaki.camscanshare.data.image

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import dagger.hilt.android.qualifiers.ApplicationContext
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.nio.FloatBuffer
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 影除去 (deshadow) filter backed by the GCDRNet appearance-enhancement
 * models (Zhang et al., IEEE TAI 2023). Mirrors scripts/deshadow_pipeline.py:
 *
 * 1. GCNet on a 512x512 square resize -> global shadow map
 * 2. DRNet on an aspect-fit resize inside a 1024x1024 replicate-padded
 *    square, fed with [input, input/shadow]
 * 3. gain map = DRNet output / DRNet input, Gaussian-smoothed, upsampled
 *    and multiplied onto the full-resolution image
 *
 * Models run with ONNX Runtime; both nets are fed BGR channel order to
 * match the original training pipeline.
 */
@Singleton
class DeshadowFilter @Inject constructor(
    @ApplicationContext private val context: Context,
    private val debugSink: ImageProcessingDebugSink,
) {

    private val env: OrtEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private val gcnet: OrtSession by lazy { createSession("deshadow/gcnet-512-fp16.onnx") }
    private val drnet: OrtSession by lazy { createSession("deshadow/drnet-1024-fp16.onnx") }

    private fun createSession(assetPath: String): OrtSession {
        val bytes = context.assets.open(assetPath).use { it.readBytes() }
        return env.createSession(bytes, OrtSession.SessionOptions())
    }

    fun apply(source: Bitmap, session: ImageProcessingDebugSession?): Bitmap {
        val width = source.width
        val height = source.height

        val rgba = Mat()
        Utils.bitmapToMat(source, rgba)
        val bgr = Mat()
        Imgproc.cvtColor(rgba, bgr, Imgproc.COLOR_RGBA2BGR)
        rgba.release()

        // 1. GCNet: global shadow map from a 512x512 square resize
        val gcStarted = SystemClock.elapsedRealtimeNanos()
        val gcInput = Mat()
        Imgproc.resize(bgr, gcInput, Size(GC_SIZE.toDouble(), GC_SIZE.toDouble()), 0.0, 0.0, Imgproc.INTER_AREA)
        val shadowChw = runModel(gcnet, matToChw(gcInput), 3, GC_SIZE, GC_SIZE)
        gcInput.release()
        val shadow = chwToMat(shadowChw, GC_SIZE, GC_SIZE)
        debugSink.recordTimingSince(session, "deshadow.gcnet", gcStarted)
        debugSink.writeMat(session, "deshadow_shadow_map", shadow, DebugMatColor.BGR)

        // 2. DRNet on an aspect-fit resize inside a replicate-padded square
        val drStarted = SystemClock.elapsedRealtimeNanos()
        val scale = DR_SIZE.toDouble() / max(width, height)
        val drWidth = if (scale < 1.0) (width * scale).roundToInt() else width
        val drHeight = if (scale < 1.0) (height * scale).roundToInt() else height
        val drImg = Mat()
        Imgproc.resize(bgr, drImg, Size(drWidth.toDouble(), drHeight.toDouble()), 0.0, 0.0, Imgproc.INTER_AREA)
        val drPad = Mat()
        Core.copyMakeBorder(drImg, drPad, 0, DR_SIZE - drHeight, 0, DR_SIZE - drWidth, Core.BORDER_REPLICATE)

        val drInput = Mat()
        drPad.convertTo(drInput, CvType.CV_32FC3, 1.0 / 255.0)
        drPad.release()

        val shadowBig = Mat()
        Imgproc.resize(shadow, shadowBig, Size(DR_SIZE.toDouble(), DR_SIZE.toDouble()), 0.0, 0.0, Imgproc.INTER_LINEAR)
        shadow.release()
        Core.max(shadowBig, Scalar.all(1e-4), shadowBig)
        val gcCorrected = Mat()
        Core.divide(drInput, shadowBig, gcCorrected)
        shadowBig.release()
        Core.min(gcCorrected, Scalar.all(1.0), gcCorrected)
        Core.max(gcCorrected, Scalar.all(0.0), gcCorrected)

        val drInputChw = FloatArray(6 * DR_SIZE * DR_SIZE)
        fillChwFromFloatMat(drInput, drInputChw, 0)
        fillChwFromFloatMat(gcCorrected, drInputChw, 3 * DR_SIZE * DR_SIZE)
        drInput.release()
        gcCorrected.release()

        val predChw = runModel(drnet, drInputChw, 6, DR_SIZE, DR_SIZE)
        val predFull = chwToMat(predChw, DR_SIZE, DR_SIZE)
        Core.min(predFull, Scalar.all(1.0), predFull)
        Core.max(predFull, Scalar.all(0.0), predFull)
        val pred8 = Mat()
        predFull.submat(0, drHeight, 0, drWidth).convertTo(pred8, CvType.CV_8UC3, 255.0)
        predFull.release()
        debugSink.recordTimingSince(session, "deshadow.drnet", drStarted)
        debugSink.writeMat(session, "deshadow_drnet_output", pred8, DebugMatColor.BGR)

        // 3. Smoothed gain map applied to the full-resolution image
        val gainStarted = SystemClock.elapsedRealtimeNanos()
        val pred32 = Mat()
        pred8.convertTo(pred32, CvType.CV_32FC3)
        pred8.release()
        Core.add(pred32, Scalar.all(GAIN_EPS), pred32)
        val drImg32 = Mat()
        drImg.convertTo(drImg32, CvType.CV_32FC3)
        drImg.release()
        Core.add(drImg32, Scalar.all(GAIN_EPS), drImg32)
        val gain = Mat()
        Core.divide(pred32, drImg32, gain)
        pred32.release()
        drImg32.release()
        Imgproc.GaussianBlur(gain, gain, Size(0.0, 0.0), GAIN_BLUR_SIGMA)
        val gainFull = Mat()
        Imgproc.resize(gain, gainFull, Size(width.toDouble(), height.toDouble()), 0.0, 0.0, Imgproc.INTER_LINEAR)
        gain.release()

        val source32 = Mat()
        bgr.convertTo(source32, CvType.CV_32FC3)
        bgr.release()
        val result32 = Mat()
        Core.multiply(source32, gainFull, result32)
        source32.release()
        gainFull.release()
        val result8 = Mat()
        result32.convertTo(result8, CvType.CV_8UC3)
        result32.release()
        debugSink.recordTimingSince(session, "deshadow.gain_apply", gainStarted)

        val resultRgba = Mat()
        Imgproc.cvtColor(result8, resultRgba, Imgproc.COLOR_BGR2RGBA)
        result8.release()
        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(resultRgba, output)
        resultRgba.release()
        return output
    }

    private fun runModel(session: OrtSession, inputChw: FloatArray, channels: Int, height: Int, width: Int): FloatArray {
        val shape = longArrayOf(1, channels.toLong(), height.toLong(), width.toLong())
        OnnxTensor.createTensor(env, FloatBuffer.wrap(inputChw), shape).use { tensor ->
            session.run(mapOf("input" to tensor)).use { results ->
                val out = results[0] as OnnxTensor
                val buffer = out.floatBuffer
                val result = FloatArray(buffer.remaining())
                buffer.get(result)
                return result
            }
        }
    }

    /** Convert an 8UC3 Mat to a normalized planar CHW float array. */
    private fun matToChw(mat: Mat): FloatArray {
        val mat32 = Mat()
        mat.convertTo(mat32, CvType.CV_32FC3, 1.0 / 255.0)
        val result = FloatArray(3 * mat.rows() * mat.cols())
        fillChwFromFloatMat(mat32, result, 0)
        mat32.release()
        return result
    }

    /** Copy a 32FC3 Mat into [dest] as planar channels starting at [destOffset]. */
    private fun fillChwFromFloatMat(mat32: Mat, dest: FloatArray, destOffset: Int) {
        val planeSize = mat32.rows() * mat32.cols()
        val channels = ArrayList<Mat>(3)
        Core.split(mat32, channels)
        channels.forEachIndexed { index, channel ->
            val plane = FloatArray(planeSize)
            channel.get(0, 0, plane)
            System.arraycopy(plane, 0, dest, destOffset + index * planeSize, planeSize)
            channel.release()
        }
    }

    /** Convert a planar CHW float array (3 channels) back into a 32FC3 Mat. */
    private fun chwToMat(chw: FloatArray, height: Int, width: Int): Mat {
        val planeSize = height * width
        val channels = ArrayList<Mat>(3)
        for (c in 0 until 3) {
            val channel = Mat(height, width, CvType.CV_32F)
            channel.put(0, 0, chw.copyOfRange(c * planeSize, (c + 1) * planeSize))
            channels.add(channel)
        }
        val merged = Mat()
        Core.merge(channels, merged)
        channels.forEach { it.release() }
        return merged
    }

    companion object {
        private const val GC_SIZE = 512
        private const val DR_SIZE = 1024
        private const val GAIN_EPS = 8.0
        private const val GAIN_BLUR_SIGMA = 2.0
    }
}
