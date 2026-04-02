package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.ui.components.computePageAspectRatio
import io.github.yusukeiwaki.camscanshare.ui.components.computePdfPageSize
import org.junit.Assert.assertEquals
import org.junit.Test

class PageAspectRatioTest {

    private val a4Portrait = 210f / 297f   // ~0.707
    private val a4Landscape = 297f / 210f  // ~1.414

    @Test
    fun `portrait image close to A4 snaps to A4 portrait`() {
        // 2100x2970 is exact A4 ratio
        assertEquals(a4Portrait, computePageAspectRatio(2100, 2970), 0.001f)
    }

    @Test
    fun `landscape image close to A4 snaps to A4 landscape`() {
        // 2970x2100 is exact A4 landscape
        assertEquals(a4Landscape, computePageAspectRatio(2970, 2100), 0.001f)
    }

    @Test
    fun `slightly off A4 portrait still snaps`() {
        // 10% off: 0.707 * 1.1 = 0.778 → still within 20% tolerance
        assertEquals(a4Portrait, computePageAspectRatio(778, 1000), 0.001f)
    }

    @Test
    fun `extremely wide panoramic uses actual ratio`() {
        // 3:1 ratio - way beyond A4
        val ratio = computePageAspectRatio(3000, 1000)
        assertEquals(3.0f, ratio, 0.001f)
    }

    @Test
    fun `extremely tall strip uses actual ratio`() {
        // 1:4 ratio
        val ratio = computePageAspectRatio(500, 2000)
        assertEquals(0.25f, ratio, 0.001f)
    }

    @Test
    fun `square image uses actual ratio`() {
        // 1:1 is not close to A4
        val ratio = computePageAspectRatio(1000, 1000)
        assertEquals(1.0f, ratio, 0.001f)
    }

    @Test
    fun `zero dimensions fallback to A4 portrait`() {
        assertEquals(a4Portrait, computePageAspectRatio(0, 0), 0.001f)
    }

    @Test
    fun `pdf page size snaps near A4 portrait to A4 canvas`() {
        val size = computePdfPageSize(2100, 2970)

        assertEquals(595, size.width)
        assertEquals(842, size.height)
    }

    @Test
    fun `pdf page size snaps near A4 landscape to A4 landscape canvas`() {
        val size = computePdfPageSize(2970, 2100)

        assertEquals(842, size.width)
        assertEquals(595, size.height)
    }

    @Test
    fun `pdf page size keeps wide landscape aspect for non A4 images`() {
        val size = computePdfPageSize(3000, 1000)

        assertEquals(842, size.width)
        assertEquals(281, size.height)
    }

    @Test
    fun `pdf page size keeps tall portrait aspect for non A4 images`() {
        val size = computePdfPageSize(500, 2000)

        assertEquals(211, size.width)
        assertEquals(842, size.height)
    }
}
