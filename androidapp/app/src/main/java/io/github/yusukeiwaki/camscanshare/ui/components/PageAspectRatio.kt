package io.github.yusukeiwaki.camscanshare.ui.components

import kotlin.math.abs
import kotlin.math.roundToInt

data class PdfPageSize(
    val width: Int,
    val height: Int,
)

/**
 * Compute the display aspect ratio (width / height) for a scanned page.
 */
fun computePageAspectRatio(imageWidth: Int, imageHeight: Int): Float {
    if (imageWidth <= 0 || imageHeight <= 0) return A4_PORTRAIT_RATIO

    val actualRatio = imageWidth.toFloat() / imageHeight.toFloat()
    return when {
        relativeDiff(actualRatio, A4_PORTRAIT_RATIO) <= A4_SNAP_TOLERANCE -> A4_PORTRAIT_RATIO
        relativeDiff(actualRatio, A4_LANDSCAPE_RATIO) <= A4_SNAP_TOLERANCE -> A4_LANDSCAPE_RATIO
        else -> actualRatio
    }
}

fun computePdfPageSize(imageWidth: Int, imageHeight: Int): PdfPageSize {
    val aspectRatio = computePageAspectRatio(imageWidth, imageHeight)

    return when {
        abs(aspectRatio - A4_PORTRAIT_RATIO) <= SNAP_EPSILON ->
            PdfPageSize(width = A4_PORTRAIT_WIDTH, height = A4_PORTRAIT_HEIGHT)

        abs(aspectRatio - A4_LANDSCAPE_RATIO) <= SNAP_EPSILON ->
            PdfPageSize(width = A4_LANDSCAPE_WIDTH, height = A4_LANDSCAPE_HEIGHT)

        aspectRatio >= 1f ->
            PdfPageSize(
                width = PDF_LONG_EDGE,
                height = maxOf(1, (PDF_LONG_EDGE / aspectRatio).roundToInt()),
            )

        else ->
            PdfPageSize(
                width = maxOf(1, (PDF_LONG_EDGE * aspectRatio).roundToInt()),
                height = PDF_LONG_EDGE,
            )
    }
}

private fun relativeDiff(actual: Float, expected: Float): Float =
    abs(actual - expected) / expected

private const val A4_SNAP_TOLERANCE = 0.2f
private const val SNAP_EPSILON = 0.0001f
private const val A4_PORTRAIT_RATIO = 210f / 297f
private const val A4_LANDSCAPE_RATIO = 297f / 210f
private const val A4_PORTRAIT_WIDTH = 595
private const val A4_PORTRAIT_HEIGHT = 842
private const val A4_LANDSCAPE_WIDTH = 842
private const val A4_LANDSCAPE_HEIGHT = 595
private const val PDF_LONG_EDGE = 842
