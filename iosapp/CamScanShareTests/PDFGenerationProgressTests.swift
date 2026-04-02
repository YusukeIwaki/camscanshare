import XCTest
@testable import CamScanShare

final class PDFGenerationProgressTests: XCTestCase {
    func testPreparingMessageUsesTotalPageCount() {
        let progress = PDFGenerationProgress(
            phase: .preparing,
            currentPage: 0,
            totalPages: 4,
            currentPageData: nil
        )

        XCTAssertEqual(progress.detailText, "4ページのPDFを準備中…")
        XCTAssertEqual(progress.fractionCompleted, 0)
    }

    func testRenderingMessageIncludesFilterNameForNonOriginalPreset() {
        let progress = PDFGenerationProgress(
            phase: .renderingPage,
            currentPage: 3,
            totalPages: 8,
            currentPageData: PDFPageData(
                imageFileName: "page-3.jpg",
                smallPreviewFileName: "page-3-small.jpg",
                largePreviewFileName: "page-3-large.jpg",
                filterPreset: .whiteboard,
                rotationDegrees: 0
            )
        )

        XCTAssertEqual(progress.detailText, "3 / 8ページをホワイトボードで処理中…")
        XCTAssertEqual(progress.fractionCompleted, 0.375)
    }

    func testRenderingMessageOmitsFilterNameForOriginalPreset() {
        let progress = PDFGenerationProgress(
            phase: .renderingPage,
            currentPage: 1,
            totalPages: 2,
            currentPageData: PDFPageData(
                imageFileName: "page-1.jpg",
                smallPreviewFileName: nil,
                largePreviewFileName: nil,
                filterPreset: .original,
                rotationDegrees: 0
            )
        )

        XCTAssertEqual(progress.detailText, "1 / 2ページを処理中…")
    }

    func testFinalizingMessageCompletesProgress() {
        let progress = PDFGenerationProgress(
            phase: .finalizing,
            currentPage: 5,
            totalPages: 5,
            currentPageData: nil
        )

        XCTAssertEqual(progress.detailText, "5ページのPDFを書き出し中…")
        XCTAssertEqual(progress.fractionCompleted, 1)
    }
}
