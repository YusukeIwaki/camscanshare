import CoreGraphics
import XCTest
@testable import CamScanShare

final class JPEGPDFWriterTests: XCTestCase {
    func testJPEGQualityIsSetToSixtyFivePercent() {
        XCTAssertEqual(JPEGPDFWriter.jpegCompressionQuality, 0.65, accuracy: 0.001)
    }

    func testWriterEmbedsPagesAsJPEGImageXObjects() {
        let data = JPEGPDFWriter.makePDFData(pages: [
            JPEGPDFPage(
                jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                imageWidth: 100,
                imageHeight: 200,
                pageRect: CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
            )
        ])

        let pdf = String(data: data, encoding: .isoLatin1) ?? ""
        XCTAssertTrue(pdf.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(pdf.contains("/Subtype /Image"))
        XCTAssertTrue(pdf.contains("/Filter /DCTDecode"))
        XCTAssertTrue(pdf.contains("/Width 100 /Height 200"))
        XCTAssertTrue(pdf.contains("/Im1 Do"))
        XCTAssertTrue(pdf.contains("xref"))
    }

    func testImagePlacementPreservesAspectRatioAndCentersImage() {
        let placement = JPEGPDFWriter.imagePlacement(for: JPEGPDFPage(
            jpegData: Data(),
            imageWidth: 100,
            imageHeight: 200,
            pageRect: CGRect(x: 0, y: 0, width: 300, height: 300)
        ))

        XCTAssertEqual(placement.x, 75, accuracy: 0.001)
        XCTAssertEqual(placement.y, 0, accuracy: 0.001)
        XCTAssertEqual(placement.width, 150, accuracy: 0.001)
        XCTAssertEqual(placement.height, 300, accuracy: 0.001)
    }
}
