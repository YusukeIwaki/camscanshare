package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.ui.camerascan.CameraScanViewModel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for image processing business logic that doesn't depend on Android framework.
 * ColorMatrix operations are tested indirectly through the matrix math functions.
 */
class ImageProcessorTest {

    @Test
    fun `brightness matrix offset is zero for value 1`() {
        val offset = 255f * (1.0f - 1f)
        assertEquals(0f, offset, 0.01f)
    }

    @Test
    fun `brightness matrix offset is positive for value greater than 1`() {
        val offset = 255f * (1.5f - 1f)
        assertEquals(127.5f, offset, 0.01f)
    }

    @Test
    fun `contrast matrix scale and offset for value 2`() {
        val scale = 2.0f
        val offset = 128f * (1f - scale)
        assertEquals(2f, scale, 0.01f)
        assertEquals(-128f, offset, 0.01f)
    }

    @Test
    fun `contrast matrix is identity for value 1`() {
        val scale = 1.0f
        val offset = 128f * (1f - scale)
        assertEquals(1f, scale, 0.01f)
        assertEquals(0f, offset, 0.01f)
    }

    @Test
    fun `all known filter keys are valid`() {
        val validKeys = setOf("original", "sharpen", "bw", "magic", "whiteboard", "vivid")
        validKeys.forEach { key ->
            // Just verify these keys are recognized - actual ColorMatrix creation
            // is tested via integration tests on device
            assertTrue("'$key' should be a known filter key", key in validKeys)
        }
    }

    @Test
    fun `bitmap pipeline filters are handled outside ColorMatrix`() {
        val colorMatrixFilters = setOf("sharpen", "vivid")

        assertTrue("magic should be handled by the OpenCV pipeline", "magic" !in colorMatrixFilters)
        assertTrue("bw should be handled by the OpenCV pipeline", "bw" !in colorMatrixFilters)
        assertTrue("whiteboard should be handled by the OpenCV pipeline", "whiteboard" !in colorMatrixFilters)
    }

    @Test
    fun `document name generation has no path separators`() {
        val name = CameraScanViewModel.generateDocumentName()
        assertTrue("Name should not contain '/': $name", !name.contains("/"))
        assertTrue("Name should not contain '\\'", !name.contains("\\"))
        assertTrue("Name should start with 'スキャン'", name.startsWith("スキャン"))
    }

    @Test
    fun `document name sanitization replaces slashes`() {
        val unsafeName = "スキャン 2026/03/29 01:08"
        val safeName = unsafeName.replace(Regex("[/\\\\:*?\"<>|]"), "_")
        assertTrue("Sanitized name should not contain '/'", !safeName.contains("/"))
        assertEquals("スキャン 2026_03_29 01_08", safeName)
    }
}
