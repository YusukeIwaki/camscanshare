package io.github.yusukeiwaki.camscanshare.ui.components

import kotlin.math.abs

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

private fun relativeDiff(actual: Float, expected: Float): Float =
    abs(actual - expected) / expected

private const val A4_SNAP_TOLERANCE = 0.2f
private const val A4_PORTRAIT_RATIO = 210f / 297f
private const val A4_LANDSCAPE_RATIO = 297f / 210f
