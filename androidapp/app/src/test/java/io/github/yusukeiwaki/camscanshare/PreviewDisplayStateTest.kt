package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.ui.components.CameraBottomControlMode
import io.github.yusukeiwaki.camscanshare.ui.components.PageEditPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.PageListPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.SmallPreviewVisualState
import io.github.yusukeiwaki.camscanshare.ui.components.cameraBottomControlMode
import io.github.yusukeiwaki.camscanshare.ui.components.pageEditPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.pageListPreviewContentMode
import io.github.yusukeiwaki.camscanshare.ui.components.resolvePagePlaceholderAspectRatio
import io.github.yusukeiwaki.camscanshare.ui.components.smallPreviewVisualState
import org.junit.Assert.assertEquals
import org.junit.Test

class PreviewDisplayStateTest {

    @Test
    fun `camera with zero captures shows close button`() {
        assertEquals(CameraBottomControlMode.CLOSE_BUTTON, cameraBottomControlMode(0))
    }

    @Test
    fun `camera with captures shows thumbnail stack`() {
        assertEquals(CameraBottomControlMode.THUMBNAIL_STACK, cameraBottomControlMode(2))
    }

    @Test
    fun `small preview without bitmap shows placeholder`() {
        assertEquals(SmallPreviewVisualState.PLACEHOLDER, smallPreviewVisualState(hasBitmap = false))
    }

    @Test
    fun `small preview with bitmap shows image`() {
        assertEquals(SmallPreviewVisualState.IMAGE, smallPreviewVisualState(hasBitmap = true))
    }

    @Test
    fun `page list uses image when bitmap is ready`() {
        val mode = pageListPreviewContentMode(
            hasBitmap = true,
            hasPreviewPath = true,
            isLoading = false,
        )
        assertEquals(PageListPreviewContentMode.IMAGE, mode)
    }

    @Test
    fun `page list uses loading placeholder while preview path is pending`() {
        val mode = pageListPreviewContentMode(
            hasBitmap = false,
            hasPreviewPath = false,
            isLoading = false,
        )
        assertEquals(PageListPreviewContentMode.LOADING_PLACEHOLDER, mode)
    }

    @Test
    fun `page list falls back to page number when decode finished without bitmap`() {
        val mode = pageListPreviewContentMode(
            hasBitmap = false,
            hasPreviewPath = true,
            isLoading = false,
        )
        assertEquals(PageListPreviewContentMode.NUMBER_PLACEHOLDER, mode)
    }

    @Test
    fun `page edit uses filter loading while working preview computes`() {
        val mode = pageEditPreviewContentMode(
            useWorkingPreview = true,
            hasWorkingBitmap = false,
            isComputing = true,
            hasLargeBitmap = false,
            hasLargePreviewPath = true,
            isLargePreviewLoading = false,
        )
        assertEquals(PageEditPreviewContentMode.FILTER_LOADING, mode)
    }

    @Test
    fun `page edit uses working preview image when ready`() {
        val mode = pageEditPreviewContentMode(
            useWorkingPreview = true,
            hasWorkingBitmap = true,
            isComputing = false,
            hasLargeBitmap = false,
            hasLargePreviewPath = true,
            isLargePreviewLoading = false,
        )
        assertEquals(PageEditPreviewContentMode.IMAGE, mode)
    }

    @Test
    fun `page edit uses preview loading while large preview is pending`() {
        val mode = pageEditPreviewContentMode(
            useWorkingPreview = false,
            hasWorkingBitmap = false,
            isComputing = false,
            hasLargeBitmap = false,
            hasLargePreviewPath = false,
            isLargePreviewLoading = false,
        )
        assertEquals(PageEditPreviewContentMode.PREVIEW_LOADING, mode)
    }

    @Test
    fun `page edit falls back to empty placeholder when preview decode failed`() {
        val mode = pageEditPreviewContentMode(
            useWorkingPreview = false,
            hasWorkingBitmap = false,
            isComputing = false,
            hasLargeBitmap = false,
            hasLargePreviewPath = true,
            isLargePreviewLoading = false,
        )
        assertEquals(PageEditPreviewContentMode.EMPTY_PLACEHOLDER, mode)
    }

    @Test
    fun `page placeholder ratio uses detected ratio when available`() {
        assertEquals(1.6f, resolvePagePlaceholderAspectRatio(1.6f), 0.001f)
    }

    @Test
    fun `page placeholder ratio falls back to A4`() {
        assertEquals(210f / 297f, resolvePagePlaceholderAspectRatio(null), 0.001f)
    }
}
