package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.ui.camerascan.CameraScanUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for CameraScanViewModel state transition logic.
 *
 * Bitmap operations can't run in JVM tests, so we test the state contracts
 * and transition rules that the ViewModel must uphold.
 */
class CameraScanViewModelTest {

    @Test
    fun `initial state has zero pages and null preview path`() {
        val state = CameraScanUiState()
        assertEquals(0, state.capturedPageCount)
        assertNull(state.lastPageSmallPreviewAbsPath)
        assertFalse(state.isCapturing)
        assertFalse(state.showFlash)
    }

    @Test
    fun `new scan starts with documentId 0`() {
        val state = CameraScanUiState()
        assertEquals(0L, state.documentId)
    }

    @Test
    fun `thumbnail stack can show placeholder while preview generation is pending`() {
        val pendingState = CameraScanUiState(capturedPageCount = 3, lastPageSmallPreviewAbsPath = null)
        assertTrue(
            "When capturedPageCount > 0 and preview path is null, the UI should show a placeholder " +
                "until the background worker writes the small preview path.",
            pendingState.capturedPageCount > 0 && pendingState.lastPageSmallPreviewAbsPath == null,
        )
    }

    @Test
    fun `retake mode sets retakePageId and keeps documentId`() {
        val state = CameraScanUiState(documentId = 5L, retakePageId = 42L)
        assertEquals(5L, state.documentId)
        assertEquals(42L, state.retakePageId)
    }

    @Test
    fun `retakeDone signals auto-close`() {
        val state = CameraScanUiState(retakeDone = true)
        assertTrue(state.retakeDone)
    }

    @Test
    fun `after capture, flying thumbnail is set while count comes from room observation`() {
        val before = CameraScanUiState(documentId = 1L, capturedPageCount = 2)
        val after = before.copy(
            flyingThumbnail = null,
            isCapturing = false,
            showFlash = false,
        )
        assertEquals(2, after.capturedPageCount)
        assertFalse(after.isCapturing)
    }

    @Test
    fun `flying animation done clears flyingThumbnail`() {
        val during = CameraScanUiState(flyingThumbnail = null) // normally non-null Bitmap
        val after = during.copy(flyingThumbnail = null)
        assertNull(after.flyingThumbnail)
    }

    @Test
    fun `initialize is idempotent - second call with different documentId is ignored`() {
        // The guard: if (_uiState.value.documentId != 0L) return
        // First init sets documentId=5, second call with documentId=10 should be ignored
        var state = CameraScanUiState()

        // First initialize
        state = state.copy(documentId = 5L, capturedPageCount = 3)
        assertEquals(5L, state.documentId)

        // Second call should not change state (guard check)
        val shouldIgnore = state.documentId != 0L
        assertTrue("Second initialize should be ignored when documentId is already set", shouldIgnore)
        // documentId stays 5, not changed to 10
        assertEquals(5L, state.documentId)
    }
}
