package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.ui.pagelist.PageListUiState
import io.github.yusukeiwaki.camscanshare.ui.pagelist.SharePdfProgress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PageListUiStateTest {

    @Test
    fun `isSharing is false by default`() {
        assertFalse(PageListUiState().isSharing)
    }

    @Test
    fun `isSharing becomes true while share progress exists`() {
        val state = PageListUiState(
            shareProgress = SharePdfProgress(
                message = "PDFを作成しています",
                currentPageIndex = 2,
                totalPages = 5,
                currentPageId = 10L,
            ),
        )

        assertTrue(state.isSharing)
    }

    @Test
    fun `share progress fraction is clamped within page bounds`() {
        val progress = SharePdfProgress(
            message = "PDFを書き出しています",
            currentPageIndex = 8,
            totalPages = 5,
        )

        assertEquals(1f, progress.progressFraction)
    }
}
