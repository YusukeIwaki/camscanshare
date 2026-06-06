package io.github.yusukeiwaki.camscanshare

import io.github.yusukeiwaki.camscanshare.ui.pagelist.JpegPdfPage
import io.github.yusukeiwaki.camscanshare.ui.pagelist.JpegPdfWriter
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class JpegPdfWriterTest {
    @Test
    fun `jpeg quality is set to sixty five percent`() {
        assertEquals(65, JpegPdfWriter.JPEG_QUALITY)
    }

    @Test
    fun `writer embeds pages as jpeg image xobjects`() {
        val output = ByteArrayOutputStream()
        JpegPdfWriter.write(
            listOf(
                JpegPdfPage(
                    jpegBytes = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte(), 0xD9.toByte()),
                    imageWidth = 100,
                    imageHeight = 200,
                    pageWidth = 595,
                    pageHeight = 842,
                ),
            ),
            output,
        )

        val pdf = output.toString(Charsets.ISO_8859_1.name())
        assertTrue(pdf.startsWith("%PDF-1.4"))
        assertTrue(pdf.contains("/Subtype /Image"))
        assertTrue(pdf.contains("/Filter /DCTDecode"))
        assertTrue(pdf.contains("/Width 100 /Height 200"))
        assertTrue(pdf.contains("/Im1 Do"))
        assertTrue(pdf.contains("xref"))
    }

    @Test
    fun `image placement preserves aspect ratio and centers image`() {
        val placement = JpegPdfWriter.imagePlacement(
            JpegPdfPage(
                jpegBytes = byteArrayOf(),
                imageWidth = 100,
                imageHeight = 200,
                pageWidth = 300,
                pageHeight = 300,
            ),
        )

        assertEquals(75f, placement.x)
        assertEquals(0f, placement.y)
        assertEquals(150f, placement.width)
        assertEquals(300f, placement.height)
    }
}
