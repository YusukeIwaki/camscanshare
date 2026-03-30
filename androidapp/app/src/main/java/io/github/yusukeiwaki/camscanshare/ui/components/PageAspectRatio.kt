package io.github.yusukeiwaki.camscanshare.ui.components

/**
 * Compute the display aspect ratio (width / height) for a scanned page.
 */
fun computePageAspectRatio(imageWidth: Int, imageHeight: Int): Float {
    if (imageWidth <= 0 || imageHeight <= 0) return 1f
    return imageWidth.toFloat() / imageHeight.toFloat()
}
