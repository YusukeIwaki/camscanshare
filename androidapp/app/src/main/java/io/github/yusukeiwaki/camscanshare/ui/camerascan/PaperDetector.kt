package io.github.yusukeiwaki.camscanshare.ui.camerascan

import android.graphics.Bitmap
import android.graphics.PointF
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc

/**
 * Detects paper/document edges in camera frames using OpenCV.
 * Returns 4 corner points of the detected document, or null if not found.
 *
 * Detection is always performed on a downscaled image (longest edge = DETECT_SIZE)
 * so that Canny/blur parameters work consistently regardless of input resolution.
 * Returned coordinates are normalized [0..1] relative to the original image.
 */
class PaperDetector {

    companion object {
        /** Longest-edge size used for detection. */
        private const val DETECT_SIZE = 500.0
    }

    init {
        OpenCVLoader.initLocal()
    }

    /**
     * Detect the largest quadrilateral in the given bitmap.
     * Returns 4 corner points in clockwise order (TL, TR, BR, BL),
     * normalized to [0..1] relative to the original image dimensions.
     */
    fun detect(bitmap: Bitmap): List<PointF>? {
        val mat = Mat()
        Utils.bitmapToMat(bitmap, mat)

        // Downscale only if larger than DETECT_SIZE, for stable detection
        val maxDim = maxOf(mat.width(), mat.height())
        val small: Mat
        if (maxDim > DETECT_SIZE) {
            val scale = DETECT_SIZE / maxDim
            small = Mat()
            Imgproc.resize(mat, small, Size(mat.width() * scale, mat.height() * scale))
        } else {
            small = mat.clone()
        }

        val gray = Mat()
        Imgproc.cvtColor(small, gray, Imgproc.COLOR_RGBA2GRAY)
        Imgproc.GaussianBlur(gray, gray, Size(5.0, 5.0), 0.0)
        Imgproc.Canny(gray, gray, 50.0, 150.0)

        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
        Imgproc.dilate(gray, gray, kernel)

        val contours = mutableListOf<MatOfPoint>()
        val hierarchy = Mat()
        Imgproc.findContours(gray, contours, hierarchy, Imgproc.RETR_EXTERNAL, Imgproc.CHAIN_APPROX_SIMPLE)

        val imageArea = small.width().toDouble() * small.height().toDouble()
        val minArea = imageArea * 0.05

        var bestCorners: List<PointF>? = null
        var bestArea = 0.0

        for (contour in contours) {
            val area = Imgproc.contourArea(contour)
            if (area < minArea || area <= bestArea) continue

            val contour2f = MatOfPoint2f(*contour.toArray())
            val peri = Imgproc.arcLength(contour2f, true)
            val approx = MatOfPoint2f()
            Imgproc.approxPolyDP(contour2f, approx, 0.02 * peri, true)

            if (approx.rows() == 4) {
                bestArea = area
                val points = approx.toArray()
                // Normalize against the downscaled image dimensions
                bestCorners = orderPoints(points).map { pt ->
                    PointF(
                        (pt.x / small.width()).toFloat(),
                        (pt.y / small.height()).toFloat(),
                    )
                }
            }

            contour2f.release()
            approx.release()
        }

        mat.release()
        small.release()
        gray.release()
        kernel.release()
        hierarchy.release()
        contours.forEach { it.release() }

        return bestCorners
    }

    /**
     * Apply perspective correction to crop the detected document region.
     * corners: 4 points in normalized [0..1] coordinates (TL, TR, BR, BL).
     * Operates on the full-resolution bitmap.
     */
    fun correctPerspective(bitmap: Bitmap, corners: List<PointF>): Bitmap {
        val mat = Mat()
        Utils.bitmapToMat(bitmap, mat)

        val w = mat.width().toDouble()
        val h = mat.height().toDouble()

        val srcPoints = corners.map { Point(it.x.toDouble() * w, it.y.toDouble() * h) }
        val srcMat = MatOfPoint2f(*srcPoints.toTypedArray())

        val widthTop = distance(srcPoints[0], srcPoints[1])
        val widthBottom = distance(srcPoints[3], srcPoints[2])
        val heightLeft = distance(srcPoints[0], srcPoints[3])
        val heightRight = distance(srcPoints[1], srcPoints[2])
        val outWidth = maxOf(widthTop, widthBottom)
        val outHeight = maxOf(heightLeft, heightRight)

        val dstMat = MatOfPoint2f(
            Point(0.0, 0.0),
            Point(outWidth, 0.0),
            Point(outWidth, outHeight),
            Point(0.0, outHeight),
        )

        val transform = Imgproc.getPerspectiveTransform(srcMat, dstMat)
        val output = Mat()
        Imgproc.warpPerspective(mat, output, transform, Size(outWidth, outHeight))

        val result = Bitmap.createBitmap(outWidth.toInt(), outHeight.toInt(), Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(output, result)

        mat.release()
        srcMat.release()
        dstMat.release()
        transform.release()
        output.release()

        return result
    }

    /** Order 4 points clockwise: top-left, top-right, bottom-right, bottom-left. */
    private fun orderPoints(points: Array<Point>): List<Point> {
        val sorted = points.toList()
        val tl = sorted.minBy { it.x + it.y }
        val br = sorted.maxBy { it.x + it.y }
        val tr = sorted.maxBy { it.x - it.y }
        val bl = sorted.minBy { it.x - it.y }
        return listOf(tl, tr, br, bl)
    }

    private fun distance(p1: Point, p2: Point): Double {
        val dx = p1.x - p2.x
        val dy = p1.y - p2.y
        return kotlin.math.sqrt(dx * dx + dy * dy)
    }
}
