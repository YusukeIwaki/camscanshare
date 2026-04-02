package io.github.yusukeiwaki.camscanshare.ui.components

enum class CameraBottomControlMode {
    CLOSE_BUTTON,
    THUMBNAIL_STACK,
}

enum class SmallPreviewVisualState {
    IMAGE,
    PLACEHOLDER,
}

enum class PageListPreviewContentMode {
    IMAGE,
    LOADING_PLACEHOLDER,
    NUMBER_PLACEHOLDER,
}

enum class PageEditPreviewContentMode {
    IMAGE,
    PREVIEW_LOADING,
    FILTER_LOADING,
    EMPTY_PLACEHOLDER,
}

fun cameraBottomControlMode(capturedPageCount: Int): CameraBottomControlMode =
    if (capturedPageCount == 0) {
        CameraBottomControlMode.CLOSE_BUTTON
    } else {
        CameraBottomControlMode.THUMBNAIL_STACK
    }

fun smallPreviewVisualState(hasBitmap: Boolean): SmallPreviewVisualState =
    if (hasBitmap) {
        SmallPreviewVisualState.IMAGE
    } else {
        SmallPreviewVisualState.PLACEHOLDER
    }

fun pageListPreviewContentMode(
    hasBitmap: Boolean,
    hasPreviewPath: Boolean,
    isLoading: Boolean,
): PageListPreviewContentMode = when {
    hasBitmap -> PageListPreviewContentMode.IMAGE
    !hasPreviewPath || isLoading -> PageListPreviewContentMode.LOADING_PLACEHOLDER
    else -> PageListPreviewContentMode.NUMBER_PLACEHOLDER
}

fun pageEditPreviewContentMode(
    useWorkingPreview: Boolean,
    hasWorkingBitmap: Boolean,
    isComputing: Boolean,
    hasLargeBitmap: Boolean,
    hasLargePreviewPath: Boolean,
    isLargePreviewLoading: Boolean,
): PageEditPreviewContentMode = when {
    useWorkingPreview && hasWorkingBitmap -> PageEditPreviewContentMode.IMAGE
    useWorkingPreview && isComputing -> PageEditPreviewContentMode.FILTER_LOADING
    !useWorkingPreview && hasLargeBitmap -> PageEditPreviewContentMode.IMAGE
    !useWorkingPreview && (!hasLargePreviewPath || isLargePreviewLoading) -> PageEditPreviewContentMode.PREVIEW_LOADING
    else -> PageEditPreviewContentMode.EMPTY_PLACEHOLDER
}

fun resolvePagePlaceholderAspectRatio(
    detectedAspectRatio: Float?,
    fallbackAspectRatio: Float = 210f / 297f,
): Float = detectedAspectRatio ?: fallbackAspectRatio
