import UIKit
import XCTest
@testable import CamScanShare

final class PreviewStorageServiceTests: XCTestCase {
    func testDeletePageAssetsRemovesSourcePersistedAndWorkingFiles() throws {
        let sourceImage = makeImage(size: CGSize(width: 120, height: 240), color: .systemRed)
        let sourceFileName = ImageStorageService.saveImage(sourceImage)
        let smallPreviewFileName = try PreviewStorageService.savePreview(
            sourceImage.scaledToFit(maxDimension: 80),
            kind: .small,
            baseName: "preview-small"
        )
        let largePreviewFileName = try PreviewStorageService.savePreview(
            sourceImage.scaledToFit(maxDimension: 160),
            kind: .large,
            baseName: "preview-large"
        )
        let workingPreviewFileName = try WorkingPreviewStorageService.saveWorkingPreview(
            sourceImage.scaledToFit(maxDimension: 160),
            sourceFileName: sourceFileName
        )

        let document = Document()
        let page = Page(
            document: document,
            sortOrder: 0,
            originalImageFileName: sourceFileName,
            smallPreviewFileName: smallPreviewFileName,
            largePreviewFileName: largePreviewFileName
        )

        XCTAssertTrue(ImageStorageService.imageExists(fileName: sourceFileName))
        XCTAssertTrue(PreviewStorageService.previewExists(fileName: smallPreviewFileName, kind: .small))
        XCTAssertTrue(PreviewStorageService.previewExists(fileName: largePreviewFileName, kind: .large))
        XCTAssertTrue(PreviewStorageService.previewExists(fileName: workingPreviewFileName, kind: .working))

        deletePageAssets(page)

        XCTAssertFalse(ImageStorageService.imageExists(fileName: sourceFileName))
        XCTAssertFalse(PreviewStorageService.previewExists(fileName: smallPreviewFileName, kind: .small))
        XCTAssertFalse(PreviewStorageService.previewExists(fileName: largePreviewFileName, kind: .large))
        XCTAssertFalse(PreviewStorageService.previewExists(fileName: workingPreviewFileName, kind: .working))
    }

    private func makeImage(size: CGSize, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
