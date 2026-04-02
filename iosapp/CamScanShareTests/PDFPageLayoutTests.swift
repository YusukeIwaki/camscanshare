import XCTest
@testable import CamScanShare

final class PDFPageLayoutTests: XCTestCase {
    func testPortraitA4LikeImageUsesPortraitA4Canvas() {
        let rect = PDFService.pageRect(for: CGSize(width: 2100, height: 2970))

        XCTAssertEqual(rect.width, PDFService.a4PortraitWidth, accuracy: 0.01)
        XCTAssertEqual(rect.height, PDFService.a4PortraitHeight, accuracy: 0.01)
    }

    func testLandscapeA4LikeImageUsesLandscapeA4Canvas() {
        let rect = PDFService.pageRect(for: CGSize(width: 2970, height: 2100))

        XCTAssertEqual(rect.width, PDFService.a4PortraitHeight, accuracy: 0.01)
        XCTAssertEqual(rect.height, PDFService.a4PortraitWidth, accuracy: 0.01)
    }

    func testWideImageUsesLandscapeCanvasMatchingImageAspectRatio() {
        let imageSize = CGSize(width: 1600, height: 900)
        let rect = PDFService.pageRect(for: imageSize)

        XCTAssertEqual(rect.width, PDFService.a4PortraitHeight, accuracy: 0.01)
        XCTAssertEqual(rect.width / rect.height, imageSize.width / imageSize.height, accuracy: 0.001)
    }

    func testInvalidImageFallsBackToPortraitA4Canvas() {
        let rect = PDFService.pageRect(for: .zero)

        XCTAssertEqual(rect.width, PDFService.a4PortraitWidth, accuracy: 0.01)
        XCTAssertEqual(rect.height, PDFService.a4PortraitHeight, accuracy: 0.01)
    }
}
