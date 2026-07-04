package io.github.yusukeiwaki.camscanshare.ui.camerascan

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.util.Log
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.nio.FloatBuffer

/**
 * Neural page-boundary segmenter.
 *
 * Runs a compact depthwise-separable U-Net (trained in
 * scripts/document_detection/) that outputs a single-channel page-probability
 * mask. This mirrors CamScanner's modern detector shape: a small CNN whose
 * Conv/Sigmoid head yields a page region that OpenCV then refines into a quad,
 * rather than pure edge/contour detection, which fails on low-contrast paper,
 * documents inside plastic folders, and near-full-frame close-ups.
 *
 * The mask is consumed by [PaperDetector] as one more candidate for
 * findBestQuad, so the existing contour/scoring/anchor refinement still applies
 * and a low-confidence mask can never override the OpenCV fallback.
 *
 * Model contract: input 1x3x[SIZE]x[SIZE] RGB float in [0,1]; output
 * 1x1x[SIZE]x[SIZE] page probability in [0,1] (sigmoid folded into the graph).
 */
class DocumentSegmenter(context: Context) {

    private val appContext = context.applicationContext
    private val env: OrtEnvironment by lazy { OrtEnvironment.getEnvironment() }
    private val session: OrtSession by lazy {
        val bytes = appContext.assets.open(ASSET_PATH).use { it.readBytes() }
        env.createSession(bytes, OrtSession.SessionOptions())
    }

    /**
     * Segment the document in [rgba] (an RGBA Mat at analysis resolution) and
     * return an 8U binary mask (page = 255) at the same width/height, or null
     * if the model is unavailable. The mask is morphologically closed so the
     * downstream contour step sees a clean region.
     */
    fun segment(rgba: Mat): Mat? {
        return try {
            segmentUnsafe(rgba)
        } catch (e: Exception) {
            Log.w(TAG, "document segmentation failed; falling back to OpenCV detection", e)
            null
        }
    }

    private fun segmentUnsafe(rgba: Mat): Mat? {
        val w = rgba.width()
        val h = rgba.height()
        if (w == 0 || h == 0) return null

        // 1. resize to the model's square input and convert to RGB [0,1]
        val square = Mat()
        Imgproc.resize(rgba, square, Size(SIZE.toDouble(), SIZE.toDouble()), 0.0, 0.0, Imgproc.INTER_AREA)
        val rgb = Mat()
        Imgproc.cvtColor(square, rgb, Imgproc.COLOR_RGBA2RGB)
        square.release()
        val rgb32 = Mat()
        rgb.convertTo(rgb32, CvType.CV_32FC3, 1.0 / 255.0)
        rgb.release()

        val chw = FloatArray(3 * SIZE * SIZE)
        val planes = ArrayList<Mat>(3)
        Core.split(rgb32, planes)
        val plane = FloatArray(SIZE * SIZE)
        for (c in 0 until 3) {
            planes[c].get(0, 0, plane)
            System.arraycopy(plane, 0, chw, c * SIZE * SIZE, SIZE * SIZE)
            planes[c].release()
        }
        rgb32.release()

        // 2. run the model
        val prob = FloatArray(SIZE * SIZE)
        OnnxTensor.createTensor(env, FloatBuffer.wrap(chw), longArrayOf(1, 3, SIZE.toLong(), SIZE.toLong()))
            .use { tensor ->
                session.run(mapOf("input" to tensor)).use { results ->
                    val out = results[0] as OnnxTensor
                    out.floatBuffer.get(prob)
                }
            }

        // 3. threshold -> binary mask, resize back to analysis resolution
        val probMat = Mat(SIZE, SIZE, CvType.CV_32F)
        probMat.put(0, 0, prob)
        val mask = Mat()
        Core.compare(probMat, Scalar(THRESHOLD), mask, Core.CMP_GE) // 8U 0/255
        probMat.release()

        val full = Mat()
        Imgproc.resize(mask, full, Size(w.toDouble(), h.toDouble()), 0.0, 0.0, Imgproc.INTER_NEAREST)
        mask.release()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(5.0, 5.0))
        Imgproc.morphologyEx(full, full, Imgproc.MORPH_CLOSE, kernel)
        kernel.release()
        return full
    }

    companion object {
        private const val TAG = "DocumentSegmenter"
        private const val ASSET_PATH = "document_detection/pageseg-320-fp16.onnx"
        private const val SIZE = 320
        private const val THRESHOLD = 0.5
    }
}
