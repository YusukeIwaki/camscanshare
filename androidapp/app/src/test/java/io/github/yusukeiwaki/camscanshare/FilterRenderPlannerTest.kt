package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.data.image.FilterRenderPlanner
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FilterRenderPlannerTest {

    @Test
    fun `magic preview is rendered from original via bitmap filter`() {
        val plan = FilterRenderPlanner.planPreview(selectedFilterKey = "magic")

        assertEquals("magic", plan.selectedFilterKey)
        assertEquals("magic", plan.bitmapFilterKey)
        assertNull(plan.colorMatrixFilterKey)
    }

    @Test
    fun `non magic preview is rendered from original via color matrix only`() {
        val plan = FilterRenderPlanner.planPreview(selectedFilterKey = "bw")

        assertEquals("bw", plan.selectedFilterKey)
        assertNull(plan.bitmapFilterKey)
        assertEquals("bw", plan.colorMatrixFilterKey)
    }

    @Test
    fun `switching from saved magic to another filter still previews from original`() {
        val plan = FilterRenderPlanner.planPreview(selectedFilterKey = "sharpen")

        assertEquals("sharpen", plan.selectedFilterKey)
        assertNull(plan.bitmapFilterKey)
        assertEquals("sharpen", plan.colorMatrixFilterKey)
    }

    @Test
    fun `switching from saved non magic to magic previews magic immediately`() {
        val plan = FilterRenderPlanner.planPreview(selectedFilterKey = "magic")

        assertEquals("magic", plan.bitmapFilterKey)
        assertNull(plan.colorMatrixFilterKey)
    }

    @Test
    fun `original compare mode bypasses all filter rendering`() {
        val plan = FilterRenderPlanner.planPreview(
            selectedFilterKey = "magic",
            showOriginal = true,
        )

        assertEquals("magic", plan.selectedFilterKey)
        assertNull(plan.bitmapFilterKey)
        assertNull(plan.colorMatrixFilterKey)
    }

    @Test
    fun `apply persists selected filter key directly`() {
        assertEquals("magic", FilterRenderPlanner.planPersistedFilter("magic"))
        assertEquals("bw", FilterRenderPlanner.planPersistedFilter("bw"))
    }
}
