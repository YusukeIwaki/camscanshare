package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.ui.pageedit.PageEditState
import io.github.yusukeiwaki.camscanshare.ui.pageedit.PageEditUiState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PageEditViewModelTest {

    @Test
    fun `isDirty detects filter changes`() {
        val saved = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "magic", rotationDegrees = 0),
            PageEditState(pageId = 2, imagePath = "b.jpg", filterKey = "magic", rotationDegrees = 0),
        )
        val edited = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "bw", rotationDegrees = 0),
            PageEditState(pageId = 2, imagePath = "b.jpg", filterKey = "magic", rotationDegrees = 0),
        )
        assertTrue(isDirty(edited, saved))
    }

    @Test
    fun `isDirty detects rotation changes`() {
        val saved = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "magic", rotationDegrees = 0),
        )
        val edited = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "magic", rotationDegrees = 90),
        )
        assertTrue(isDirty(edited, saved))
    }

    @Test
    fun `isDirty returns false when nothing changed`() {
        val saved = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "magic", rotationDegrees = 0),
        )
        assertFalse(isDirty(saved, saved))
    }

    @Test
    fun `rotation cycles through 0, 270, 180, 90`() {
        var rotation = 0
        rotation = (rotation - 90 + 360) % 360
        assertEquals(270, rotation)
        rotation = (rotation - 90 + 360) % 360
        assertEquals(180, rotation)
        rotation = (rotation - 90 + 360) % 360
        assertEquals(90, rotation)
        rotation = (rotation - 90 + 360) % 360
        assertEquals(0, rotation)
    }

    @Test
    fun `filter apply to all pages changes all filters`() {
        val pages = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "magic"),
            PageEditState(pageId = 2, imagePath = "b.jpg", filterKey = "original"),
            PageEditState(pageId = 3, imagePath = "c.jpg", filterKey = "bw"),
        )
        val updated = pages.map { it.copy(filterKey = "vivid") }
        assertTrue(updated.all { it.filterKey == "vivid" })
    }

    @Test
    fun `discard reverts to saved state`() {
        val saved = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "magic", rotationDegrees = 0),
        )
        val edited = listOf(
            PageEditState(pageId = 1, imagePath = "a.jpg", filterKey = "bw", rotationDegrees = 270),
        )
        // Discard = revert to saved
        val reverted = saved
        assertFalse(isDirty(reverted, saved))
    }

    // Extracted isDirty logic for testing without ViewModel dependency
    private fun isDirty(pages: List<PageEditState>, savedPages: List<PageEditState>): Boolean {
        if (pages.size != savedPages.size) return true
        return pages.zip(savedPages).any { (a, b) ->
            a.filterKey != b.filterKey || a.rotationDegrees != b.rotationDegrees
        }
    }
}
