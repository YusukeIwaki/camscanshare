package io.github.yusukeiwaki.camscanshare.ui.components

/**
 * Compute the display aspect ratio (width / height) for a scanned page.
 *
 * - If the image aspect ratio is close to A4 (portrait or landscape),
 *   snap to the exact A4 ratio so the page looks like a standard sheet.
 * - Otherwise use the actual image aspect ratio as-is.
 */
fun computePageAspectRatio(imageWidth: Int, imageHeight: Int): Float {
    if (imageWidth <= 0 || imageHeight <= 0) return A4_PORTRAIT

    val imageRatio = imageWidth.toFloat() / imageHeight.toFloat()

    val tolerance = 0.20f // ±20%
    return when {
        imageRatio in (A4_PORTRAIT * (1 - tolerance))..(A4_PORTRAIT * (1 + tolerance)) -> A4_PORTRAIT
        imageRatio in (A4_LANDSCAPE * (1 - tolerance))..(A4_LANDSCAPE * (1 + tolerance)) -> A4_LANDSCAPE
        else -> imageRatio
    }
}

private const val A4_PORTRAIT = 210f / 297f   // ~0.707
private const val A4_LANDSCAPE = 297f / 210f  // ~1.414
