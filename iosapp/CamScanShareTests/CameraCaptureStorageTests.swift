import UIKit
import XCTest
@testable import CamScanShare

@MainActor
final class CameraCaptureStorageTests: XCTestCase {
    func testAbandonedCaptureDeletesUncommittedImageFile() async throws {
        var viewModel: CameraScanViewModel? = CameraScanViewModel()
        await viewModel?.processAndStoreCapturedImage(makeImage())
        let page = try XCTUnwrap(viewModel?.capturedPages.first)
        XCTAssertTrue(ImageStorageService.imageExists(fileName: page.imageFileName))
        XCTAssertEqual(viewModel?.pageCount, 1)

        viewModel = nil
        XCTAssertFalse(ImageStorageService.imageExists(fileName: page.imageFileName))
    }

    func testCommittedCaptureKeepsFileAndReleasesSessionState() async throws {
        var viewModel: CameraScanViewModel? = CameraScanViewModel()
        await viewModel?.processAndStoreCapturedImage(makeImage())
        let page = try XCTUnwrap(viewModel?.capturedPages.first)
        defer { ImageStorageService.deleteImage(fileName: page.imageFileName) }

        viewModel?.commitCapturedPages()
        XCTAssertEqual(viewModel?.pageCount, 0)
        XCTAssertNil(viewModel?.latestThumbnail)
        viewModel = nil
        XCTAssertTrue(ImageStorageService.imageExists(fileName: page.imageFileName))
    }

    private func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160), format: format).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }
    }
}
