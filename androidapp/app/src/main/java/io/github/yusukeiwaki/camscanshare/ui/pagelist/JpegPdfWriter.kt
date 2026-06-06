package io.github.yusukeiwaki.camscanshare.ui.pagelist

import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.Locale

data class JpegPdfPage(
    val jpegBytes: ByteArray,
    val imageWidth: Int,
    val imageHeight: Int,
    val pageWidth: Int,
    val pageHeight: Int,
)

data class PdfImagePlacement(
    val x: Float,
    val y: Float,
    val width: Float,
    val height: Float,
)

object JpegPdfWriter {
    const val JPEG_QUALITY = 65

    fun imagePlacement(page: JpegPdfPage): PdfImagePlacement {
        val scale = minOf(
            page.pageWidth.toFloat() / page.imageWidth.toFloat(),
            page.pageHeight.toFloat() / page.imageHeight.toFloat(),
        )
        val width = page.imageWidth * scale
        val height = page.imageHeight * scale
        return PdfImagePlacement(
            x = (page.pageWidth - width) / 2f,
            y = (page.pageHeight - height) / 2f,
            width = width,
            height = height,
        )
    }

    fun write(pages: List<JpegPdfPage>, output: OutputStream) {
        val pdf = ByteArrayOutputStream()
        pdf.writeAscii("%PDF-1.4\n%\u00E2\u00E3\u00CF\u00D3\n")

        val maxObjectId = 2 + pages.size * 3
        val offsets = LongArray(maxObjectId + 1)

        writeObject(pdf, offsets, 1, "<< /Type /Catalog /Pages 2 0 R >>")

        val kids = pages.indices.joinToString(" ") { index -> "${pageObjectId(index)} 0 R" }
        writeObject(pdf, offsets, 2, "<< /Type /Pages /Kids [ $kids ] /Count ${pages.size} >>")

        pages.forEachIndexed { index, page ->
            val pageObjectId = pageObjectId(index)
            val imageObjectId = imageObjectId(index)
            val contentObjectId = contentObjectId(index)
            writeObject(
                pdf,
                offsets,
                pageObjectId,
                "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 ${page.pageWidth} ${page.pageHeight} ] " +
                    "/Resources << /XObject << /Im${index + 1} $imageObjectId 0 R >> >> " +
                    "/Contents $contentObjectId 0 R >>",
            )
            writeStreamObject(
                pdf,
                offsets,
                imageObjectId,
                "<< /Type /XObject /Subtype /Image /Width ${page.imageWidth} /Height ${page.imageHeight} " +
                    "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${page.jpegBytes.size} >>",
                page.jpegBytes,
            )
            val placement = imagePlacement(page)
            val content = buildString {
                append("q\n")
                append("${pdfNumber(placement.width)} 0 0 ${pdfNumber(placement.height)} ")
                append("${pdfNumber(placement.x)} ${pdfNumber(placement.y)} cm\n")
                append("/Im${index + 1} Do\n")
                append("Q\n")
            }.toByteArray(Charsets.ISO_8859_1)
            writeStreamObject(
                pdf,
                offsets,
                contentObjectId,
                "<< /Length ${content.size} >>",
                content,
            )
        }

        val xrefOffset = pdf.size()
        pdf.writeAscii("xref\n")
        pdf.writeAscii("0 ${maxObjectId + 1}\n")
        pdf.writeAscii("0000000000 65535 f \n")
        for (objectId in 1..maxObjectId) {
            pdf.writeAscii(String.format(Locale.US, "%010d 00000 n \n", offsets[objectId]))
        }
        pdf.writeAscii(
            "trailer\n" +
                "<< /Size ${maxObjectId + 1} /Root 1 0 R >>\n" +
                "startxref\n" +
                "$xrefOffset\n" +
                "%%EOF\n",
        )
        output.write(pdf.toByteArray())
    }

    private fun pageObjectId(index: Int): Int = 3 + index * 3

    private fun imageObjectId(index: Int): Int = pageObjectId(index) + 1

    private fun contentObjectId(index: Int): Int = pageObjectId(index) + 2

    private fun writeObject(
        pdf: ByteArrayOutputStream,
        offsets: LongArray,
        objectId: Int,
        body: String,
    ) {
        offsets[objectId] = pdf.size().toLong()
        pdf.writeAscii("$objectId 0 obj\n")
        pdf.writeAscii(body)
        pdf.writeAscii("\nendobj\n")
    }

    private fun writeStreamObject(
        pdf: ByteArrayOutputStream,
        offsets: LongArray,
        objectId: Int,
        dictionary: String,
        stream: ByteArray,
    ) {
        offsets[objectId] = pdf.size().toLong()
        pdf.writeAscii("$objectId 0 obj\n")
        pdf.writeAscii("$dictionary\nstream\n")
        pdf.write(stream)
        pdf.writeAscii("\nendstream\nendobj\n")
    }

    private fun pdfNumber(value: Float): String =
        if (value % 1f == 0f) {
            value.toInt().toString()
        } else {
            String.format(Locale.US, "%.4f", value).trimEnd('0').trimEnd('.')
        }

    private fun ByteArrayOutputStream.writeAscii(value: String) {
        write(value.toByteArray(Charsets.ISO_8859_1))
    }
}
