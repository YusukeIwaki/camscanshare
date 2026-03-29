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
 *
 * Uses multiple detection strategies (varying blur, threshold, morphology)
 * and picks the best quadrilateral found. This makes detection robust
 * across different lighting conditions, paper colors, and backgrounds.
 */
class PaperDetector {

    companion object {
        private const val DETECT_SIZE = 500.0
        private const val MIN_AREA_RATIO = 0.05
        /** Number of recent frames to keep for stabilization. */
        private const val STABLE_BUFFER_SIZE = 5
        /** Minimum number of detections in the buffer to consider it stable. */
        private const val STABLE_MIN_DETECTIONS = 2
        /** How long to hold the last valid detection after detection is lost (ms). */
        private const val HOLD_DURATION_MS = 500L
    }

    init {
        OpenCVLoader.initLocal()
    }

    // --- Stabilization buffer for real-time overlay ---
    private data class TimedDetection(val corners: List<PointF>?, val timestamp: Long)

    private val recentDetections = ArrayDeque<TimedDetection>(STABLE_BUFFER_SIZE + 1)
    private var lastValidResult: List<PointF>? = null
    private var lastValidTimestamp: Long = 0L

    /**
     * Detect with stabilization:
     * - Buffers recent results and returns the median when enough frames agree.
     * - When detection is lost, keeps showing the last valid result for HOLD_DURATION_MS
     *   so the overlay doesn't flicker on momentary detection failures.
     */
    fun detectStabilized(bitmap: Bitmap): List<PointF>? {
        val now = System.currentTimeMillis()
        val singleResult = detect(bitmap)
        synchronized(recentDetections) {
            recentDetections.addLast(TimedDetection(singleResult, now))
            if (recentDetections.size > STABLE_BUFFER_SIZE) recentDetections.removeFirst()

            val validResults = recentDetections.mapNotNull { it.corners }
            if (validResults.size >= STABLE_MIN_DETECTIONS) {
                val median = medianCorners(validResults)
                lastValidResult = median
                lastValidTimestamp = now
                return median
            }

            // Not enough detections — hold the last valid result for a short period
            if (lastValidResult != null && (now - lastValidTimestamp) < HOLD_DURATION_MS) {
                return lastValidResult
            }

            lastValidResult = null
            return null
        }
    }

    /**
     * Single-frame detection (no stabilization). Used for capture-time detection
     * where we want the most accurate result for the specific captured image.
     */
    fun detect(bitmap: Bitmap): List<PointF>? {
        val mat = Mat()
        Utils.bitmapToMat(bitmap, mat)

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

        val imageArea = small.width().toDouble() * small.height().toDouble()
        val minArea = imageArea * MIN_AREA_RATIO

        // Try multiple detection strategies and keep the best-scoring result
        var bestCorners: List<PointF>? = null
        var bestScore = 0.0

        for (strategy in strategies) {
            val edges = strategy.detectEdges(gray)
            val result = findBestQuad(edges, minArea, bestScore, small.width(), small.height())
            edges.release()
            if (result != null) {
                bestCorners = result.first
                bestScore = result.second
            }
        }

        mat.release()
        small.release()
        gray.release()

        return bestCorners
    }

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

    // --- Detection strategies ---

    private data class DetectionResult(val corners: List<PointF>, val area: Double)

    private interface EdgeStrategy {
        fun detectEdges(gray: Mat): Mat
    }

    /**
     * Canny edge detection with minimal dilate to close small gaps in edges.
     * A single dilate with a 3x3 kernel bridges 1-2 pixel gaps without merging
     * distant edges (unlike morphological close with larger kernels).
     */
    private class CannyStrategy(
        val blurSize: Int,
        val cannyLow: Double,
        val cannyHigh: Double,
    ) : EdgeStrategy {
        override fun detectEdges(gray: Mat): Mat {
            val blurred = Mat()
            Imgproc.GaussianBlur(gray, blurred, Size(blurSize.toDouble(), blurSize.toDouble()), 0.0)
            val edges = Mat()
            Imgproc.Canny(blurred, edges, cannyLow, cannyHigh)
            blurred.release()
            // Minimal dilate (3x3, one pass) to close tiny gaps in edges
            val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
            Imgproc.dilate(edges, edges, kernel)
            kernel.release()
            return edges
        }
    }

    private val strategies: List<EdgeStrategy> = listOf(
        // Strategy 1: low thresholds — catches faint paper edges (cf. AdityaPai: 30,50)
        CannyStrategy(blurSize = 5, cannyLow = 30.0, cannyHigh = 50.0),
        // Strategy 2: medium thresholds
        CannyStrategy(blurSize = 5, cannyLow = 50.0, cannyHigh = 150.0),
        // Strategy 3: high thresholds — cuts noise on busy backgrounds (cf. savannahar: 75,200)
        CannyStrategy(blurSize = 5, cannyLow = 75.0, cannyHigh = 200.0),
        // Strategy 4: heavier blur for low contrast / uneven lighting
        CannyStrategy(blurSize = 11, cannyLow = 30.0, cannyHigh = 100.0),
    )

    private fun findBestQuad(
        edges: Mat,
        minArea: Double,
        currentBestScore: Double,
        imageWidth: Int,
        imageHeight: Int,
    ): Pair<List<PointF>, Double>? {
        val contours = mutableListOf<MatOfPoint>()
        val hierarchy = Mat()
        // RETR_LIST: retrieve all contours without hierarchy. This is critical —
        // RETR_EXTERNAL only returns outermost contours, so a paper contour nested
        // inside a larger floor/desk contour would be missed.
        Imgproc.findContours(edges, contours, hierarchy, Imgproc.RETR_LIST, Imgproc.CHAIN_APPROX_SIMPLE)

        val imageArea = imageWidth.toDouble() * imageHeight.toDouble()
        var bestCorners: List<PointF>? = null
        var bestScore = currentBestScore

        // Sort by area descending, inspect only the largest candidates (cf. savannahar: top 5)
        val topContours = contours
            .filter { Imgproc.contourArea(it) >= minArea }
            .sortedByDescending { Imgproc.contourArea(it) }
            .take(10)

        for (contour in topContours) {
            val area = Imgproc.contourArea(contour)

            val contour2f = MatOfPoint2f(*contour.toArray())
            val peri = Imgproc.arcLength(contour2f, true)

            for (epsilonPct in listOf(0.02, 0.03, 0.04, 0.05)) {
                val approx = MatOfPoint2f()
                Imgproc.approxPolyDP(contour2f, approx, epsilonPct * peri, true)

                if (approx.rows() == 4 && isConvex(approx)) {
                    val score = scoreQuad(approx, area, imageArea)
                    if (score > bestScore) {
                        bestScore = score
                        val points = approx.toArray()
                        bestCorners = orderPoints(points).map { pt ->
                            PointF(
                                (pt.x / imageWidth).toFloat(),
                                (pt.y / imageHeight).toFloat(),
                            )
                        }
                    }
                    approx.release()
                    break
                }
                approx.release()
            }

            contour2f.release()
        }

        hierarchy.release()
        contours.forEach { it.release() }

        return if (bestCorners != null) Pair(bestCorners, bestScore) else null
    }

    /**
     * Score a quadrilateral by how "document-like" it is.
     * Prefers rectangles (parallel opposite sides, ~90° angles) over arbitrary quadrilaterals.
     * Area is a factor but doesn't dominate — a smaller rectangle beats a larger trapezoid.
     */
    private fun scoreQuad(quad: MatOfPoint2f, area: Double, imageArea: Double): Double {
        val pts = quad.toArray()
        val ordered = orderPoints(pts)

        // 1. Area ratio (0..1): how much of the image the quad covers
        val areaRatio = area / imageArea

        // 2. Rectangularity: how close each angle is to 90°
        //    Perfect rectangle = 1.0, worst = 0.0
        var angleScore = 0.0
        for (i in ordered.indices) {
            val a = ordered[i]
            val b = ordered[(i + 1) % 4]
            val c = ordered[(i + 2) % 4]
            val angle = angleDeg(a, b, c)
            // Score: 1.0 at 90°, 0.0 at 60° or 120°
            angleScore += 1.0 - (kotlin.math.abs(angle - 90.0) / 30.0).coerceIn(0.0, 1.0)
        }
        angleScore /= 4.0 // normalize to 0..1

        // 3. Parallelism: opposite sides should have similar lengths
        val widthTop = distance(ordered[0], ordered[1])
        val widthBottom = distance(ordered[3], ordered[2])
        val heightLeft = distance(ordered[0], ordered[3])
        val heightRight = distance(ordered[1], ordered[2])
        val widthRatio = minOf(widthTop, widthBottom) / maxOf(widthTop, widthBottom)
        val heightRatio = minOf(heightLeft, heightRight) / maxOf(heightLeft, heightRight)
        val parallelScore = (widthRatio + heightRatio) / 2.0

        // Combined score: rectangularity and parallelism dominate; area is minor.
        // This prevents a large non-rectangular quad (e.g. floor corner) from winning
        // over a smaller but truly rectangular paper.
        return angleScore * 0.45 + parallelScore * 0.35 + areaRatio * 0.20
    }

    /** Check that the quadrilateral is convex (rejects self-intersecting shapes). */
    private fun isConvex(quad: MatOfPoint2f): Boolean {
        val points = quad.toArray()
        if (points.size != 4) return false
        val contour = MatOfPoint(*points.map { org.opencv.core.Point(it.x, it.y) }.toTypedArray())
        val result = Imgproc.isContourConvex(contour)
        contour.release()
        return result
    }

    /** Angle at vertex b, formed by segments b->a and b->c, in degrees. */
    private fun angleDeg(a: Point, b: Point, c: Point): Double {
        val ba = Point(a.x - b.x, a.y - b.y)
        val bc = Point(c.x - b.x, c.y - b.y)
        val dot = ba.x * bc.x + ba.y * bc.y
        val magBA = kotlin.math.sqrt(ba.x * ba.x + ba.y * ba.y)
        val magBC = kotlin.math.sqrt(bc.x * bc.x + bc.y * bc.y)
        if (magBA == 0.0 || magBC == 0.0) return 0.0
        val cosAngle = (dot / (magBA * magBC)).coerceIn(-1.0, 1.0)
        return Math.toDegrees(kotlin.math.acos(cosAngle))
    }

    /**
     * Compute per-coordinate median across multiple detection results.
     * Each result is 4 PointF (TL, TR, BR, BL). The median of each x/y
     * across frames gives a stable, jitter-free set of corners.
     */
    private fun medianCorners(results: List<List<PointF>>): List<PointF> {
        return (0 until 4).map { cornerIdx ->
            val xs = results.map { it[cornerIdx].x }.sorted()
            val ys = results.map { it[cornerIdx].y }.sorted()
            val mid = xs.size / 2
            PointF(xs[mid], ys[mid])
        }
    }

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
