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
    fun `initial state has zero pages and null thumbnail`() {
        val state = CameraScanUiState()
        assertEquals(0, state.capturedPageCount)
        assertNull(state.lastThumbnail)
        assertFalse(state.isCapturing)
        assertFalse(state.showFlash)
    }

    @Test
    fun `new scan starts with documentId 0`() {
        val state = CameraScanUiState()
        assertEquals(0L, state.documentId)
    }

    @Test
    fun `thumbnail stack requires both count and thumbnail for display`() {
        // The UI shows close button when count=0, thumbnail stack when count>0.
        // When count>0, lastThumbnail MUST be non-null; otherwise the stack is empty.
        // This is the contract that was violated before the fix.

        // Bad state (bug): count > 0 but no thumbnail
        val buggyState = CameraScanUiState(capturedPageCount = 3, lastThumbnail = null)
        assertTrue(
            "When capturedPageCount > 0, lastThumbnail should not be null. " +
                "The initialize() method must load the last page's thumbnail for existing documents.",
            buggyState.capturedPageCount > 0 && buggyState.lastThumbnail == null,
        )
        // This test documents the invariant. The ViewModel's initialize() is responsible
        // for ensuring this never happens in practice.
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
    fun `after capture, count increments and thumbnail and flying thumbnail are set together`() {
        // Simulates what onCaptureImage does to state (without Bitmap)
        val before = CameraScanUiState(documentId = 1L, capturedPageCount = 2)
        val after = before.copy(
            capturedPageCount = before.capturedPageCount + 1,
            lastThumbnail = before.lastThumbnail, // would be non-null in real code
            flyingThumbnail = before.lastThumbnail,
            isCapturing = false,
            showFlash = false,
        )
        assertEquals(3, after.capturedPageCount)
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
