import CoreGraphics
import Foundation

struct JPEGPDFPage {
    let jpegData: Data
    let imageWidth: Int
    let imageHeight: Int
    let pageRect: CGRect
}

struct JPEGPDFImagePlacement: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

enum JPEGPDFWriter {
    static let jpegCompressionQuality: CGFloat = 0.65

    static func imagePlacement(for page: JPEGPDFPage) -> JPEGPDFImagePlacement {
        let imageWidth = CGFloat(page.imageWidth)
        let imageHeight = CGFloat(page.imageHeight)
        let scale = min(page.pageRect.width / imageWidth, page.pageRect.height / imageHeight)
        let width = imageWidth * scale
        let height = imageHeight * scale
        return JPEGPDFImagePlacement(
            x: (page.pageRect.width - width) / 2,
            y: (page.pageRect.height - height) / 2,
            width: width,
            height: height
        )
    }

    static func makePDFData(pages: [JPEGPDFPage]) -> Data {
        var pdf = Data()
        appendAscii("%PDF-1.4\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n", to: &pdf)

        let maxObjectId = 2 + pages.count * 3
        var offsets = Array(repeating: 0, count: maxObjectId + 1)

        writeObject(id: 1, body: "<< /Type /Catalog /Pages 2 0 R >>", to: &pdf, offsets: &offsets)

        let kids = pages.indices
            .map { "\(pageObjectId(for: $0)) 0 R" }
            .joined(separator: " ")
        writeObject(
            id: 2,
            body: "<< /Type /Pages /Kids [ \(kids) ] /Count \(pages.count) >>",
            to: &pdf,
            offsets: &offsets
        )

        for (index, page) in pages.enumerated() {
            let pageObjectId = pageObjectId(for: index)
            let imageObjectId = imageObjectId(for: index)
            let contentObjectId = contentObjectId(for: index)
            writeObject(
                id: pageObjectId,
                body: "<< /Type /Page /Parent 2 0 R /MediaBox [ 0 0 \(pdfNumber(page.pageRect.width)) \(pdfNumber(page.pageRect.height)) ] " +
                    "/Resources << /XObject << /Im\(index + 1) \(imageObjectId) 0 R >> >> " +
                    "/Contents \(contentObjectId) 0 R >>",
                to: &pdf,
                offsets: &offsets
            )

            writeStreamObject(
                id: imageObjectId,
                dictionary: "<< /Type /XObject /Subtype /Image /Width \(page.imageWidth) /Height \(page.imageHeight) " +
                    "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(page.jpegData.count) >>",
                stream: page.jpegData,
                to: &pdf,
                offsets: &offsets
            )

            let placement = imagePlacement(for: page)
            let content = """
            q
            \(pdfNumber(placement.width)) 0 0 \(pdfNumber(placement.height)) \(pdfNumber(placement.x)) \(pdfNumber(placement.y)) cm
            /Im\(index + 1) Do
            Q

            """
            writeStreamObject(
                id: contentObjectId,
                dictionary: "<< /Length \(content.utf8.count) >>",
                stream: Data(content.utf8),
                to: &pdf,
                offsets: &offsets
            )
        }

        let xrefOffset = pdf.count
        appendAscii("xref\n", to: &pdf)
        appendAscii("0 \(maxObjectId + 1)\n", to: &pdf)
        appendAscii("0000000000 65535 f \n", to: &pdf)
        for objectId in 1...maxObjectId {
            appendAscii(
                String(format: "%010d 00000 n \n", locale: Locale(identifier: "en_US_POSIX"), offsets[objectId]),
                to: &pdf
            )
        }
        appendAscii(
            "trailer\n" +
                "<< /Size \(maxObjectId + 1) /Root 1 0 R >>\n" +
                "startxref\n" +
                "\(xrefOffset)\n" +
                "%%EOF\n",
            to: &pdf
        )
        return pdf
    }

    private static func pageObjectId(for index: Int) -> Int {
        3 + index * 3
    }

    private static func imageObjectId(for index: Int) -> Int {
        pageObjectId(for: index) + 1
    }

    private static func contentObjectId(for index: Int) -> Int {
        pageObjectId(for: index) + 2
    }

    private static func writeObject(
        id: Int,
        body: String,
        to pdf: inout Data,
        offsets: inout [Int]
    ) {
        offsets[id] = pdf.count
        appendAscii("\(id) 0 obj\n", to: &pdf)
        appendAscii(body, to: &pdf)
        appendAscii("\nendobj\n", to: &pdf)
    }

    private static func writeStreamObject(
        id: Int,
        dictionary: String,
        stream: Data,
        to pdf: inout Data,
        offsets: inout [Int]
    ) {
        offsets[id] = pdf.count
        appendAscii("\(id) 0 obj\n", to: &pdf)
        appendAscii("\(dictionary)\nstream\n", to: &pdf)
        pdf.append(stream)
        appendAscii("\nendstream\nendobj\n", to: &pdf)
    }

    private static func pdfNumber(_ value: CGFloat) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        var formatted = String(
            format: "%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            Double(value)
        )
        while formatted.last == "0" {
            formatted.removeLast()
        }
        if formatted.last == "." {
            formatted.removeLast()
        }
        return formatted
    }

    private static func appendAscii(_ string: String, to data: inout Data) {
        data.append(Data(string.utf8))
    }
}
