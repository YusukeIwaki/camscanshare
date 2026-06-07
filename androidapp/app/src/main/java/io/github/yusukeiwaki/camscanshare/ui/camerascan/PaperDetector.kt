package io.github.yusukeiwaki.camscanshare.ui.camerascan

import android.graphics.Bitmap
import android.graphics.PointF
import android.os.SystemClock
import io.github.yusukeiwaki.camscanshare.data.image.DebugMatColor
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessingDebugSession
import io.github.yusukeiwaki.camscanshare.data.image.ImageProcessingDebugSink
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc

/**
 * Detects paper/document edges in camera frames using OpenCV.
 *
 * Uses multiple detection strategies (varying blur, threshold, morphology)
 * and picks the best quadrilateral found. This makes detection robust
 * across different lighting conditions, paper colors, and backgrounds.
 */
class PaperDetector(
    private val debugSink: ImageProcessingDebugSink = ImageProcessingDebugSink.noOp(),
) {

    companion object {
        private const val DETECT_SIZE_PREVIEW = 500.0
        private const val DETECT_SIZE_CAPTURE = 900.0
        private const val MIN_AREA_RATIO_PREVIEW = 0.05
        private const val MIN_AREA_RATIO_CAPTURE = 0.02
        private const val COLORED_MIN_AREA_RATIO_PREVIEW = 0.08
        private const val COLORED_MIN_AREA_RATIO_CAPTURE = 0.04
        private const val PAPER_MIN_AREA_RATIO_PREVIEW = 0.05
        private const val PAPER_MIN_AREA_RATIO_CAPTURE = 0.03
        private const val A4_PORTRAIT = 210.0 / 297.0
        private const val A4_LANDSCAPE = 297.0 / 210.0
        private const val A4_TOLERANCE = 0.20
        private const val EDGE_SUPPORT_SCORE_WEIGHT = 0.18
        /** Number of recent frames to keep for stabilization. */
        private const val STABLE_BUFFER_SIZE = 7
        /** Minimum number of detections in the buffer to consider it stable. */
        private const val STABLE_MIN_DETECTIONS = 3
        /** How long to hold the last valid detection after detection is lost (ms). */
        private const val HOLD_DURATION_MS = 500L
    }

    init {
        OpenCVLoader.initLocal()
    }

    // --- Stabilization buffer for real-time overlay ---
    private enum class DetectionMode {
        PREVIEW,
        CAPTURE,
    }

    private data class DetectionConfig(
        val mode: DetectionMode,
        val detectSize: Double,
        val minAreaRatio: Double,
        val coloredMinAreaRatio: Double,
        val paperMinAreaRatio: Double,
        val maxCandidates: Int,
        val coloredMaxCandidates: Int,
        val epsilonCandidates: List<Double>,
        val allowMinAreaRect: Boolean,
        val strategies: List<EdgeStrategy>,
    )

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
        val singleResult = detectInternal(bitmap, mode = DetectionMode.PREVIEW, session = null)
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
        return detectForCapture(bitmap)
    }

    fun detectForCapture(bitmap: Bitmap, anchorCorners: List<PointF>? = null): List<PointF>? {
        val session = debugSink.startSession(
            category = "paper-detection",
            label = "capture",
            metadata = mapOf(
                "inputWidth" to bitmap.width.toString(),
                "inputHeight" to bitmap.height.toString(),
                "platform" to "android",
                "mode" to DetectionMode.CAPTURE.name.lowercase(),
                "anchor" to (anchorCorners?.size == 4).toString(),
            ),
        )
        return detectInternal(bitmap, mode = DetectionMode.CAPTURE, anchorCorners = anchorCorners, session = session)
    }

    private fun detectInternal(
        bitmap: Bitmap,
        mode: DetectionMode,
        anchorCorners: List<PointF>? = null,
        session: ImageProcessingDebugSession?,
    ): List<PointF>? {
        val config = detectionConfig(mode)
        val started = SystemClock.elapsedRealtimeNanos()
        debugSink.writeBitmap(session, "input", bitmap)
        val mat = Mat()
        Utils.bitmapToMat(bitmap, mat)

        val maxDim = maxOf(mat.width(), mat.height())
        val small: Mat
        if (maxDim > config.detectSize) {
            val scale = config.detectSize / maxDim
            small = Mat()
            Imgproc.resize(mat, small, Size(mat.width() * scale, mat.height() * scale))
        } else {
            small = mat.clone()
        }

        val gray = Mat()
        Imgproc.cvtColor(small, gray, Imgproc.COLOR_RGBA2GRAY)
        debugSink.writeMat(session, "analysis_rgba", small, DebugMatColor.RGBA)
        debugSink.writeMat(session, "grayscale", gray)
        val edgeSupportMap = buildEdgeSupportMap(gray)
        debugSink.writeMat(session, "edge_support", edgeSupportMap)

        val imageArea = small.width().toDouble() * small.height().toDouble()
        val analysisWidth = small.width()
        val analysisHeight = small.height()
        val minArea = imageArea * config.minAreaRatio
        val coloredPaperMinArea = imageArea * config.coloredMinAreaRatio
        val paperMinArea = imageArea * config.paperMinAreaRatio

        var bestCorners: List<PointF>? = null
        var bestScore = 0.0

        val coloredPaperMask = buildColoredPaperCandidateMask(small)
        debugSink.writeMat(session, "colored_paper_mask", coloredPaperMask)
        findBestQuad(
            edges = coloredPaperMask,
            minArea = coloredPaperMinArea,
            currentBestScore = bestScore,
            imageWidth = small.width(),
            imageHeight = small.height(),
            maxCandidates = config.coloredMaxCandidates,
            epsilonCandidates = config.epsilonCandidates,
            debugSession = session,
            debugSource = small,
            debugLabel = "colored_paper",
            scoreBonus = 0.18,
            allowMinAreaRect = config.allowMinAreaRect,
            anchorCorners = anchorCorners,
            edgeSupportMap = edgeSupportMap,
        )?.let { result ->
            bestCorners = result.first
            bestScore = result.second
        }
        coloredPaperMask.release()

        val paperMask = buildPaperCandidateMask(small)
        debugSink.writeMat(session, "paper_mask", paperMask)
        findBestQuad(
            edges = paperMask,
            minArea = paperMinArea,
            currentBestScore = bestScore,
            imageWidth = small.width(),
            imageHeight = small.height(),
            maxCandidates = config.maxCandidates,
            epsilonCandidates = config.epsilonCandidates,
            debugSession = session,
            debugSource = small,
            debugLabel = "paper",
            scoreBonus = 0.10,
            allowMinAreaRect = config.allowMinAreaRect,
            anchorCorners = anchorCorners,
            edgeSupportMap = edgeSupportMap,
        )?.let { result ->
            bestCorners = result.first
            bestScore = result.second
        }
        paperMask.release()

        val adaptiveMask = buildAdaptiveCandidateMask(gray)
        debugSink.writeMat(session, "adaptive_mask", adaptiveMask)
        findBestQuad(
            edges = adaptiveMask,
            minArea = minArea,
            currentBestScore = bestScore,
            imageWidth = small.width(),
            imageHeight = small.height(),
            maxCandidates = config.maxCandidates,
            epsilonCandidates = config.epsilonCandidates,
            debugSession = session,
            debugSource = small,
            debugLabel = "adaptive",
            scoreBonus = 0.0,
            allowMinAreaRect = config.allowMinAreaRect,
            anchorCorners = anchorCorners,
            edgeSupportMap = edgeSupportMap,
        )?.let { result ->
            bestCorners = result.first
            bestScore = result.second
        }
        adaptiveMask.release()

        for ((index, strategy) in config.strategies.withIndex()) {
            val strategyStarted = SystemClock.elapsedRealtimeNanos()
            val edges = strategy.detectEdges(gray, keepDebugMats = session?.isEnabled == true)
            edges.blurred?.let { debugSink.writeMat(session, "strategy_${index}_${strategy.label}_blurred", it) }
            edges.rawEdges?.let { debugSink.writeMat(session, "strategy_${index}_${strategy.label}_edges", it) }
            debugSink.writeMat(session, "strategy_${index}_${strategy.label}_dilated_edges", edges.dilatedEdges)
            val result = findBestQuad(
                edges = edges.dilatedEdges,
                minArea = minArea,
                currentBestScore = bestScore,
                imageWidth = small.width(),
                imageHeight = small.height(),
                maxCandidates = config.maxCandidates,
                epsilonCandidates = config.epsilonCandidates,
                debugSession = session,
                debugSource = small,
                debugLabel = "strategy_${index}_${strategy.label}",
                scoreBonus = 0.0,
                allowMinAreaRect = config.allowMinAreaRect,
                anchorCorners = anchorCorners,
                edgeSupportMap = edgeSupportMap,
            )
            edges.release()
            if (result != null) {
                bestCorners = result.first
                bestScore = result.second
            }
            debugSink.recordTimingSince(
                session,
                "paper_detection.strategy",
                strategyStarted,
                mapOf(
                    "strategy" to strategy.label,
                    "index" to index.toString(),
                    "bestScoreAfterStrategy" to bestScore.toString(),
                ),
            )
        }

        val resultCorners = bestCorners ?: anchorCorners?.takeIf { it.size == 4 }?.let(::clampCorners)
        if (resultCorners != null) {
            val overlay = drawQuadOverlay(small, resultCorners)
            debugSink.writeMat(session, "selected_quad_overlay", overlay, DebugMatColor.RGBA)
            overlay.release()
            debugSink.writeText(session, "selected_quad.json", cornersJson(resultCorners, bestScore))
        }

        mat.release()
        small.release()
        gray.release()
        edgeSupportMap.release()

        debugSink.recordTimingSince(
            session,
            "paper_detection.total",
            started,
            mapOf(
                "result" to when {
                    bestCorners != null -> "quad"
                    resultCorners != null -> "anchor_fallback"
                    else -> "none"
                },
                "bestScore" to bestScore.toString(),
                "mode" to config.mode.name.lowercase(),
                "analysisWidth" to analysisWidth.toString(),
                "analysisHeight" to analysisHeight.toString(),
                "detectSize" to config.detectSize.toString(),
                "minAreaRatio" to config.minAreaRatio.toString(),
                "anchor" to (anchorCorners?.size == 4).toString(),
            ),
        )
        return resultCorners
    }

    fun correctDocumentGeometry(bitmap: Bitmap, corners: List<PointF>): Bitmap {
        val session = debugSink.startSession(
            category = "document-geometry",
            label = "capture",
            metadata = mapOf(
                "inputWidth" to bitmap.width.toString(),
                "inputHeight" to bitmap.height.toString(),
                "platform" to "android",
            ),
        )
        val started = SystemClock.elapsedRealtimeNanos()
        debugSink.writeBitmap(session, "input", bitmap)
        debugSink.writeText(session, "input_corners.json", cornersJson(corners, score = null))
        val mat = Mat()
        Utils.bitmapToMat(bitmap, mat)

        val w = mat.width().toDouble()
        val h = mat.height().toDouble()

        val srcPoints = orderPoints(corners.map { Point(it.x.toDouble() * w, it.y.toDouble() * h) }.toTypedArray())
        val srcMat = MatOfPoint2f(*srcPoints.toTypedArray())

        val widthTop = distance(srcPoints[0], srcPoints[1])
        val widthBottom = distance(srcPoints[3], srcPoints[2])
        val heightLeft = distance(srcPoints[0], srcPoints[3])
        val heightRight = distance(srcPoints[1], srcPoints[2])
        val outWidth = maxOf(1.0, (widthTop + widthBottom) / 2.0)
        val outHeight = maxOf(1.0, (heightLeft + heightRight) / 2.0)

        val dstMat = MatOfPoint2f(
            Point(0.0, 0.0),
            Point(outWidth, 0.0),
            Point(outWidth, outHeight),
            Point(0.0, outHeight),
        )

        val transform = Imgproc.getPerspectiveTransform(srcMat, dstMat)
        val output = Mat()
        Imgproc.warpPerspective(mat, output, transform, Size(outWidth, outHeight))
        debugSink.writeMat(session, "warped_rgba", output, DebugMatColor.RGBA)

        val step0 = Bitmap.createBitmap(outWidth.toInt(), outHeight.toInt(), Bitmap.Config.ARGB_8888)
        Utils.matToBitmap(output, step0)

        mat.release()
        srcMat.release()
        dstMat.release()
        transform.release()
        output.release()

        val targetRatio = estimateTargetPaperRatio(srcPoints)
        val normalized = normalizeDocumentAspect(step0, targetRatio)
        debugSink.writeBitmap(session, "output", normalized)
        debugSink.recordTimingSince(
            session,
            "document_geometry.total",
            started,
            mapOf(
                "warpedWidth" to outWidth.toInt().toString(),
                "warpedHeight" to outHeight.toInt().toString(),
                "targetRatio" to (targetRatio?.toString() ?: "none"),
                "outputWidth" to normalized.width.toString(),
                "outputHeight" to normalized.height.toString(),
            ),
        )
        return normalized
    }

    // --- Detection strategies ---

    private data class DetectionResult(val corners: List<PointF>, val area: Double)

    private data class EdgeDetectionResult(
        val blurred: Mat?,
        val rawEdges: Mat?,
        val dilatedEdges: Mat,
    ) {
        fun release() {
            blurred?.release()
            rawEdges?.release()
            dilatedEdges.release()
        }
    }

    private interface EdgeStrategy {
        val label: String
        fun detectEdges(gray: Mat, keepDebugMats: Boolean): EdgeDetectionResult
    }

    /**
     * Canny edge detection with dilate to close gaps in edges.
     * dilateSize is adapted to image resolution: low-res analysis frames need
     * slightly larger kernels (5x5) because edges have more gaps per pixel,
     * while high-res capture images only need minimal bridging (3x3).
     */
    private class CannyStrategy(
        val blurSize: Int,
        val cannyLow: Double,
        val cannyHigh: Double,
        val dilateSize: Int,
    ) : EdgeStrategy {
        override val label: String =
            "canny_b${blurSize}_l${cannyLow.toInt()}_h${cannyHigh.toInt()}_d${dilateSize}"

        override fun detectEdges(gray: Mat, keepDebugMats: Boolean): EdgeDetectionResult {
            val blurred = Mat()
            Imgproc.GaussianBlur(gray, blurred, Size(blurSize.toDouble(), blurSize.toDouble()), 0.0)
            val rawEdges = Mat()
            Imgproc.Canny(blurred, rawEdges, cannyLow, cannyHigh)
            val dilatedEdges = if (keepDebugMats) rawEdges.clone() else rawEdges
            val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(dilateSize.toDouble(), dilateSize.toDouble()))
            Imgproc.dilate(dilatedEdges, dilatedEdges, kernel)
            kernel.release()
            return if (keepDebugMats) {
                EdgeDetectionResult(blurred, rawEdges, dilatedEdges)
            } else {
                blurred.release()
                EdgeDetectionResult(null, null, dilatedEdges)
            }
        }
    }

    private class AutoCannyStrategy(
        val blurSize: Int,
        val sigma: Double,
        val dilateSize: Int,
    ) : EdgeStrategy {
        override val label: String =
            "auto_canny_b${blurSize}_s${(sigma * 100).toInt()}_d${dilateSize}"

        override fun detectEdges(gray: Mat, keepDebugMats: Boolean): EdgeDetectionResult {
            val blurred = Mat()
            Imgproc.GaussianBlur(gray, blurred, Size(blurSize.toDouble(), blurSize.toDouble()), 0.0)
            val median = medianGrayValue(blurred)
            val cannyLow = ((1.0 - sigma) * median).coerceIn(0.0, 255.0)
            val cannyHigh = maxOf(cannyLow + 24.0, (1.0 + sigma) * median).coerceIn(0.0, 255.0)
            val rawEdges = Mat()
            Imgproc.Canny(blurred, rawEdges, cannyLow, cannyHigh)
            val dilatedEdges = if (keepDebugMats) rawEdges.clone() else rawEdges
            val kernel = Imgproc.getStructuringElement(
                Imgproc.MORPH_RECT,
                Size(dilateSize.toDouble(), dilateSize.toDouble()),
            )
            Imgproc.dilate(dilatedEdges, dilatedEdges, kernel)
            kernel.release()
            return if (keepDebugMats) {
                EdgeDetectionResult(blurred, rawEdges, dilatedEdges)
            } else {
                blurred.release()
                EdgeDetectionResult(null, null, dilatedEdges)
            }
        }

        private fun medianGrayValue(gray: Mat): Double {
            val total = (gray.total() * gray.channels()).toInt()
            if (total <= 0) return 0.0

            val bytes = ByteArray(total)
            gray.get(0, 0, bytes)
            val histogram = IntArray(256)
            bytes.forEach { value ->
                histogram[value.toInt() and 0xFF] += 1
            }

            val target = total / 2
            var cumulative = 0
            for (value in histogram.indices) {
                cumulative += histogram[value]
                if (cumulative > target) return value.toDouble()
            }
            return 255.0
        }
    }

    /** Preview keeps the historical 500px fast path for real-time overlay tracking. */
    private val previewStrategies: List<EdgeStrategy> = listOf(
        CannyStrategy(blurSize = 5, cannyLow = 30.0, cannyHigh = 50.0, dilateSize = 5),
        CannyStrategy(blurSize = 5, cannyLow = 50.0, cannyHigh = 150.0, dilateSize = 5),
        CannyStrategy(blurSize = 5, cannyLow = 75.0, cannyHigh = 200.0, dilateSize = 5),
        CannyStrategy(blurSize = 11, cannyLow = 30.0, cannyHigh = 100.0, dilateSize = 5),
    )

    /** Capture evaluates more edge variants at a larger analysis size. */
    private val captureStrategies: List<EdgeStrategy> = listOf(
        CannyStrategy(blurSize = 3, cannyLow = 30.0, cannyHigh = 50.0, dilateSize = 3),
        CannyStrategy(blurSize = 5, cannyLow = 50.0, cannyHigh = 150.0, dilateSize = 3),
        CannyStrategy(blurSize = 7, cannyLow = 75.0, cannyHigh = 200.0, dilateSize = 3),
        AutoCannyStrategy(blurSize = 3, sigma = 0.33, dilateSize = 3),
        AutoCannyStrategy(blurSize = 5, sigma = 0.50, dilateSize = 3),
    )

    private fun detectionConfig(mode: DetectionMode): DetectionConfig {
        return when (mode) {
            DetectionMode.PREVIEW -> DetectionConfig(
                mode = mode,
                detectSize = DETECT_SIZE_PREVIEW,
                minAreaRatio = MIN_AREA_RATIO_PREVIEW,
                coloredMinAreaRatio = COLORED_MIN_AREA_RATIO_PREVIEW,
                paperMinAreaRatio = PAPER_MIN_AREA_RATIO_PREVIEW,
                maxCandidates = 12,
                coloredMaxCandidates = 24,
                epsilonCandidates = listOf(0.02, 0.03, 0.04, 0.05),
                allowMinAreaRect = false,
                strategies = previewStrategies,
            )
            DetectionMode.CAPTURE -> DetectionConfig(
                mode = mode,
                detectSize = DETECT_SIZE_CAPTURE,
                minAreaRatio = MIN_AREA_RATIO_CAPTURE,
                coloredMinAreaRatio = COLORED_MIN_AREA_RATIO_CAPTURE,
                paperMinAreaRatio = PAPER_MIN_AREA_RATIO_CAPTURE,
                maxCandidates = 40,
                coloredMaxCandidates = 40,
                epsilonCandidates = listOf(0.015, 0.02, 0.025, 0.03, 0.04, 0.05, 0.06),
                allowMinAreaRect = false,
                strategies = captureStrategies,
            )
        }
    }

    private fun findBestQuad(
        edges: Mat,
        minArea: Double,
        currentBestScore: Double,
        imageWidth: Int,
        imageHeight: Int,
        maxCandidates: Int = 10,
        epsilonCandidates: List<Double>,
        debugSession: ImageProcessingDebugSession? = null,
        debugSource: Mat? = null,
        debugLabel: String = "strategy",
        scoreBonus: Double = 0.0,
        allowMinAreaRect: Boolean = false,
        anchorCorners: List<PointF>? = null,
        edgeSupportMap: Mat? = null,
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

        // Sort by area descending, inspect the largest candidates
        val topContours = contours
            .filter { Imgproc.contourArea(it) >= minArea }
            .sortedByDescending { Imgproc.contourArea(it) }
            .take(maxCandidates)
        if (debugSession?.isEnabled == true && debugSource != null) {
            val overlay = debugSource.clone()
            Imgproc.drawContours(overlay, topContours, -1, Scalar(255.0, 191.0, 0.0, 255.0), 2)
            debugSink.writeMat(debugSession, "${debugLabel}_contours_overlay", overlay, DebugMatColor.RGBA)
            overlay.release()
        }

        for (contour in topContours) {
            val area = Imgproc.contourArea(contour)

            val contour2f = MatOfPoint2f(*contour.toArray())
            val peri = Imgproc.arcLength(contour2f, true)
            var acceptedApprox = false

            for (epsilonPct in epsilonCandidates) {
                val approx = MatOfPoint2f()
                Imgproc.approxPolyDP(contour2f, approx, epsilonPct * peri, true)

                if (approx.rows() == 4 && isConvex(approx)) {
                    acceptedApprox = true
                    val points = approx.toArray()
                    val score = scoreQuad(approx, area, imageArea, imageWidth, imageHeight) +
                        scoreEdgeSupport(points, edgeSupportMap, imageWidth, imageHeight) * EDGE_SUPPORT_SCORE_WEIGHT +
                        scoreBonus -
                        coloredEdgePenalty(points, imageWidth, imageHeight, scoreBonus)
                    if (score > bestScore) {
                        val normalizedCorners = orderPoints(points).map { pt ->
                            PointF(
                                (pt.x / imageWidth).toFloat(),
                                (pt.y / imageHeight).toFloat(),
                            )
                        }
                        if (matchesAnchor(normalizedCorners, anchorCorners)) {
                            bestScore = score
                            bestCorners = normalizedCorners
                        }
                    }
                }
                approx.release()
            }

            if (!acceptedApprox && allowMinAreaRect) {
                val rect = Imgproc.minAreaRect(contour2f)
                val box = Array(4) { Point() }
                rect.points(box)
                val rectQuad = MatOfPoint2f(*box)
                val score = scoreQuad(rectQuad, area, imageArea, imageWidth, imageHeight) +
                    scoreEdgeSupport(box, edgeSupportMap, imageWidth, imageHeight) * EDGE_SUPPORT_SCORE_WEIGHT +
                    scoreBonus -
                    coloredEdgePenalty(box, imageWidth, imageHeight, scoreBonus)
                if (score > bestScore) {
                    val normalizedCorners = orderPoints(box).map { pt ->
                        PointF(
                            (pt.x / imageWidth).toFloat(),
                            (pt.y / imageHeight).toFloat(),
                        )
                    }
                    if (matchesAnchor(normalizedCorners, anchorCorners)) {
                        bestScore = score
                        bestCorners = normalizedCorners
                    }
                }
                rectQuad.release()
            }

            contour2f.release()
        }

        hierarchy.release()
        contours.forEach { it.release() }

        return if (bestCorners != null) Pair(bestCorners, bestScore) else null
    }

    private fun matchesAnchor(candidate: List<PointF>, anchor: List<PointF>?): Boolean {
        if (anchor == null || anchor.size != 4 || candidate.size != 4) return true

        val orderedCandidate = orderNormalizedPoints(candidate)
        val orderedAnchor = orderNormalizedPoints(anchor)
        val distances = orderedCandidate.zip(orderedAnchor).map { (candidatePoint, anchorPoint) ->
            distance(candidatePoint, anchorPoint)
        }
        val meanDistance = distances.average()
        val maxDistance = distances.maxOrNull() ?: 0.0
        val centerDistance = distance(centerOf(orderedCandidate), centerOf(orderedAnchor))
        val candidateArea = normalizedPolygonArea(orderedCandidate)
        val anchorArea = normalizedPolygonArea(orderedAnchor)
        val areaRatio = minOf(candidateArea, anchorArea) / maxOf(candidateArea, anchorArea, 0.0001)

        return meanDistance <= 0.16 &&
            maxDistance <= 0.28 &&
            centerDistance <= 0.17 &&
            areaRatio >= 0.50
    }

    private fun orderNormalizedPoints(points: List<PointF>): List<PointF> {
        return orderPoints(points.map { Point(it.x.toDouble(), it.y.toDouble()) }.toTypedArray()).map {
            PointF(it.x.toFloat(), it.y.toFloat())
        }
    }

    private fun centerOf(points: List<PointF>): PointF {
        return PointF(
            (points.sumOf { it.x.toDouble() } / points.size).toFloat(),
            (points.sumOf { it.y.toDouble() } / points.size).toFloat(),
        )
    }

    private fun distance(lhs: PointF, rhs: PointF): Double {
        val dx = lhs.x - rhs.x
        val dy = lhs.y - rhs.y
        return kotlin.math.sqrt((dx * dx + dy * dy).toDouble())
    }

    private fun normalizedPolygonArea(points: List<PointF>): Double {
        if (points.size != 4) return 0.0
        var area = 0.0
        for (index in points.indices) {
            val current = points[index]
            val next = points[(index + 1) % points.size]
            area += current.x.toDouble() * next.y.toDouble() - current.y.toDouble() * next.x.toDouble()
        }
        return kotlin.math.abs(area) / 2.0
    }

    private fun clampCorners(corners: List<PointF>): List<PointF> {
        return corners.map { point ->
            PointF(point.x.coerceIn(0f, 1f), point.y.coerceIn(0f, 1f))
        }
    }

    private fun coloredEdgePenalty(points: Array<Point>, imageWidth: Int, imageHeight: Int, scoreBonus: Double): Double {
        if (scoreBonus <= 0.0) return 0.0
        val marginX = imageWidth * 0.02
        val marginY = imageHeight * 0.02
        val touchesLeft = points.any { it.x < marginX }
        val touchesRight = points.any { it.x > imageWidth - marginX }
        val touchesTop = points.any { it.y < marginY }
        val touchesBottom = points.any { it.y > imageHeight - marginY }
        val touchedSides = listOf(touchesLeft, touchesRight, touchesTop, touchesBottom).count { it }
        return if (touchedSides >= 3) 0.35 else 0.0
    }

    private fun buildAdaptiveCandidateMask(gray: Mat): Mat {
        val blurred = Mat()
        Imgproc.GaussianBlur(gray, blurred, Size(5.0, 5.0), 0.0)

        val mask = Mat()
        Imgproc.adaptiveThreshold(
            blurred,
            mask,
            255.0,
            Imgproc.ADAPTIVE_THRESH_GAUSSIAN_C,
            Imgproc.THRESH_BINARY,
            31,
            15.0,
        )
        Core.bitwise_not(mask, mask)

        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(5.0, 5.0))
        Imgproc.morphologyEx(mask, mask, Imgproc.MORPH_CLOSE, kernel, Point(-1.0, -1.0), 2)

        blurred.release()
        kernel.release()
        return mask
    }

    private fun buildEdgeSupportMap(gray: Mat): Mat {
        val blurred = Mat()
        Imgproc.GaussianBlur(gray, blurred, Size(5.0, 5.0), 0.0)

        val canny = Mat()
        Imgproc.Canny(blurred, canny, 40.0, 70.0, 3, false)

        val gradX = Mat()
        val gradY = Mat()
        Imgproc.Sobel(blurred, gradX, CvType.CV_16S, 1, 0, 3)
        Imgproc.Sobel(blurred, gradY, CvType.CV_16S, 0, 1, 3)

        val absX = Mat()
        val absY = Mat()
        Core.convertScaleAbs(gradX, absX)
        Core.convertScaleAbs(gradY, absY)

        val sobel = Mat()
        Core.addWeighted(absX, 0.5, absY, 0.5, 0.0, sobel)

        val support = Mat()
        Core.max(canny, sobel, support)
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(3.0, 3.0))
        Imgproc.dilate(support, support, kernel)

        listOf(blurred, canny, gradX, gradY, absX, absY, sobel, kernel).forEach { it.release() }
        return support
    }

    private fun scoreEdgeSupport(
        points: Array<Point>,
        edgeSupportMap: Mat?,
        imageWidth: Int,
        imageHeight: Int,
    ): Double {
        if (edgeSupportMap == null || edgeSupportMap.empty() || points.size != 4) return 0.0

        val ordered = orderPoints(points)
        val lineMask = Mat.zeros(edgeSupportMap.size(), CvType.CV_8U)
        val thickness = maxOf(3, minOf(imageWidth, imageHeight) / 120)
        for (index in ordered.indices) {
            Imgproc.line(
                lineMask,
                ordered[index],
                ordered[(index + 1) % ordered.size],
                Scalar.all(255.0),
                thickness,
            )
        }

        val support = (Core.mean(edgeSupportMap, lineMask).`val`[0] / 255.0).coerceIn(0.0, 1.0)
        lineMask.release()
        return support
    }

    private fun buildPaperCandidateMask(source: Mat): Mat {
        val lab = Mat()
        val rgb = Mat()
        Imgproc.cvtColor(source, rgb, Imgproc.COLOR_RGBA2RGB)
        Imgproc.cvtColor(rgb, lab, Imgproc.COLOR_RGB2Lab)
        val channels = mutableListOf<Mat>()
        Core.split(lab, channels)

        val a32 = Mat()
        val b32 = Mat()
        channels[1].convertTo(a32, CvType.CV_32F)
        channels[2].convertTo(b32, CvType.CV_32F)
        Core.subtract(a32, Scalar(128.0), a32)
        Core.subtract(b32, Scalar(128.0), b32)

        val chroma = Mat()
        Core.magnitude(a32, b32, chroma)

        val brightMask = Mat()
        val lowChromaMask = Mat()
        Imgproc.threshold(channels[0], brightMask, 145.0, 255.0, Imgproc.THRESH_BINARY)
        Imgproc.threshold(chroma, lowChromaMask, 42.0, 255.0, Imgproc.THRESH_BINARY_INV)
        lowChromaMask.convertTo(lowChromaMask, CvType.CV_8U)

        val mask = Mat()
        Core.bitwise_and(brightMask, lowChromaMask, mask)
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(9.0, 9.0))
        Imgproc.morphologyEx(mask, mask, Imgproc.MORPH_CLOSE, kernel, Point(-1.0, -1.0), 2)
        Imgproc.morphologyEx(mask, mask, Imgproc.MORPH_OPEN, kernel, Point(-1.0, -1.0), 1)

        listOf(rgb, lab, a32, b32, chroma, brightMask, lowChromaMask, kernel).forEach { it.release() }
        channels.forEach { it.release() }
        return mask
    }

    private fun buildColoredPaperCandidateMask(source: Mat): Mat {
        val lab = Mat()
        val rgb = Mat()
        Imgproc.cvtColor(source, rgb, Imgproc.COLOR_RGBA2RGB)
        Imgproc.cvtColor(rgb, lab, Imgproc.COLOR_RGB2Lab)
        val channels = mutableListOf<Mat>()
        Core.split(lab, channels)

        val a32 = Mat()
        val b32 = Mat()
        channels[1].convertTo(a32, CvType.CV_32F)
        channels[2].convertTo(b32, CvType.CV_32F)
        Core.subtract(a32, Scalar(128.0), a32)
        Core.subtract(b32, Scalar(128.0), b32)

        val chroma = Mat()
        Core.magnitude(a32, b32, chroma)

        val brightMask = Mat()
        val chromaHighMask = Mat()
        val chromaLowMask = Mat()
        val aMask = Mat()
        val bMask = Mat()
        Imgproc.threshold(channels[0], brightMask, 120.0, 255.0, Imgproc.THRESH_BINARY)
        Imgproc.threshold(chroma, chromaHighMask, 10.0, 255.0, Imgproc.THRESH_BINARY)
        Imgproc.threshold(chroma, chromaLowMask, 70.0, 255.0, Imgproc.THRESH_BINARY_INV)
        Imgproc.threshold(channels[1], aMask, 130.0, 255.0, Imgproc.THRESH_BINARY)
        Imgproc.threshold(channels[2], bMask, 150.0, 255.0, Imgproc.THRESH_BINARY_INV)
        chromaHighMask.convertTo(chromaHighMask, CvType.CV_8U)
        chromaLowMask.convertTo(chromaLowMask, CvType.CV_8U)

        val mask = Mat()
        Core.bitwise_and(brightMask, chromaHighMask, mask)
        Core.bitwise_and(mask, chromaLowMask, mask)
        Core.bitwise_and(mask, aMask, mask)
        Core.bitwise_and(mask, bMask, mask)

        val closeKernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(7.0, 7.0))
        val openKernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, Size(5.0, 5.0))
        Imgproc.morphologyEx(mask, mask, Imgproc.MORPH_CLOSE, closeKernel, Point(-1.0, -1.0), 1)
        Imgproc.morphologyEx(mask, mask, Imgproc.MORPH_OPEN, openKernel, Point(-1.0, -1.0), 1)

        listOf(rgb, lab, a32, b32, chroma, brightMask, chromaHighMask, chromaLowMask, aMask, bMask, closeKernel, openKernel)
            .forEach { it.release() }
        channels.forEach { it.release() }
        return mask
    }

    private fun drawQuadOverlay(source: Mat, corners: List<PointF>?): Mat {
        val overlay = source.clone()
        if (corners == null || corners.size != 4) return overlay

        val points = corners.map {
            Point(
                it.x.toDouble() * source.width().toDouble(),
                it.y.toDouble() * source.height().toDouble(),
            )
        }
        val contour = MatOfPoint(*points.toTypedArray())
        Imgproc.polylines(overlay, listOf(contour), true, Scalar(26.0, 115.0, 232.0, 255.0), 4)
        points.forEach { point ->
            Imgproc.circle(overlay, point, 8, Scalar(26.0, 115.0, 232.0, 255.0), -1)
        }
        contour.release()
        return overlay
    }

    private fun cornersJson(corners: List<PointF>?, score: Double?): String {
        val pointsJson = corners.orEmpty().joinToString(prefix = "[", postfix = "]") { point ->
            "{\"x\":${point.x},\"y\":${point.y}}"
        }
        val scoreJson = score?.let { ",\"score\":$it" } ?: ""
        return "{\"corners\":$pointsJson$scoreJson}"
    }

    /**
     * Score a quadrilateral by how "document-like" it is.
     * Prefers rectangles (parallel opposite sides, ~90° angles) over arbitrary quadrilaterals.
     * Area is a factor but doesn't dominate — a smaller rectangle beats a larger trapezoid.
     */
    private fun scoreQuad(
        quad: MatOfPoint2f,
        area: Double,
        imageArea: Double,
        imageWidth: Int,
        imageHeight: Int,
    ): Double {
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
        val centerX = ordered.sumOf { it.x } / ordered.size.toDouble()
        val centerY = ordered.sumOf { it.y } / ordered.size.toDouble()
        val normalizedDx = centerX / imageWidth.coerceAtLeast(1).toDouble() - 0.5
        val normalizedDy = centerY / imageHeight.coerceAtLeast(1).toDouble() - 0.5
        val centerDistance = kotlin.math.sqrt(normalizedDx * normalizedDx + normalizedDy * normalizedDy)
        val centerScore = (1.0 - centerDistance / 0.50).coerceIn(0.0, 1.0)

        // Combined score: rectangularity and parallelism dominate; area is minor.
        // This prevents a large non-rectangular quad (e.g. floor corner) from winning
        // over a smaller but truly rectangular paper.
        return angleScore * 0.45 + parallelScore * 0.35 + areaRatio * 0.10 + centerScore * 0.10
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
        if (points.size != 4) return points.toList()

        val centerX = points.sumOf { it.x } / points.size.toDouble()
        val centerY = points.sumOf { it.y } / points.size.toDouble()
        val angleSorted = points.sortedBy { kotlin.math.atan2(it.y - centerY, it.x - centerX) }.toMutableList()
        if (signedArea(angleSorted) < 0.0) {
            angleSorted.reverse()
        }
        val startIndex = angleSorted.indices.minBy { index ->
            angleSorted[index].x + angleSorted[index].y
        }
        return List(4) { offset -> angleSorted[(startIndex + offset) % 4] }
    }

    private fun signedArea(points: List<Point>): Double {
        var area = 0.0
        for (index in points.indices) {
            val current = points[index]
            val next = points[(index + 1) % points.size]
            area += current.x * next.y - current.y * next.x
        }
        return area / 2.0
    }

    private fun distance(p1: Point, p2: Point): Double {
        val dx = p1.x - p2.x
        val dy = p1.y - p2.y
        return kotlin.math.sqrt(dx * dx + dy * dy)
    }

    private fun estimateTargetPaperRatio(points: List<Point>): Double? {
        if (points.size != 4) return null

        val ordered = orderPoints(points.toTypedArray())
        val widthTop = distance(ordered[0], ordered[1])
        val widthBottom = distance(ordered[3], ordered[2])
        val heightLeft = distance(ordered[0], ordered[3])
        val heightRight = distance(ordered[1], ordered[2])

        val maxWidth = maxOf(widthTop, widthBottom)
        val minWidth = maxOf(1.0, minOf(widthTop, widthBottom))
        val maxHeight = maxOf(heightLeft, heightRight)
        val minHeight = maxOf(1.0, minOf(heightLeft, heightRight))

        val observedRatio = maxWidth / maxHeight
        val widthSkew = maxWidth / minWidth
        val heightSkew = maxHeight / minHeight
        val estimatedRatio = if (observedRatio < 1.05 && widthSkew > 1.20 && widthSkew >= heightSkew) {
            minWidth / maxHeight
        } else {
            observedRatio
        }

        return snapRatioToPaper(estimatedRatio)
    }

    private fun snapRatioToPaper(imageRatio: Double, tolerance: Double = A4_TOLERANCE): Double? {
        val portraitDelta = kotlin.math.abs(imageRatio / A4_PORTRAIT - 1.0)
        val landscapeDelta = kotlin.math.abs(imageRatio / A4_LANDSCAPE - 1.0)
        val (bestRatio, bestDelta) = if (portraitDelta <= landscapeDelta) {
            A4_PORTRAIT to portraitDelta
        } else {
            A4_LANDSCAPE to landscapeDelta
        }
        return if (bestDelta <= tolerance) bestRatio else null
    }

    private fun normalizeDocumentAspect(bitmap: Bitmap, targetRatio: Double?): Bitmap {
        if (targetRatio == null) return bitmap

        val width = bitmap.width
        val height = bitmap.height
        val area = width.toDouble() * height.toDouble()
        val targetWidth = kotlin.math.sqrt(area * targetRatio).toInt().coerceAtLeast(1)
        val targetHeight = kotlin.math.sqrt(area / targetRatio).toInt().coerceAtLeast(1)

        if (targetWidth == width && targetHeight == height) return bitmap

        val resized = Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
        if (resized !== bitmap) {
            bitmap.recycle()
        }
        return resized
    }
}
