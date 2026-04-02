import UIKit
import XCTest
@testable import CamScanShare

final class PreviewDisplayStateTests: XCTestCase {
    func testPageCardUsesImageWhenLargePreviewExists() {
        let state = PreviewDisplayState.pageCard(
            largePreviewFileName: "page-large.jpg",
            aspectRatio: 0.72,
            isRegenerating: false
        )

        XCTAssertEqual(
            state,
            .image(fileName: "page-large.jpg", kind: .large, aspectRatio: 0.72)
        )
    }

    func testPageCardUsesLoadingWhenPreviewIsMissingAndRegenerating() {
        let state = PreviewDisplayState.pageCard(
            largePreviewFileName: nil,
            aspectRatio: 0.72,
            isRegenerating: true
        )

        XCTAssertEqual(state, .loading(aspectRatio: 0.72))
    }

    func testPageEditorPrefersWorkingPreviewOverPersistedPreview() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }

        let state = PreviewDisplayState.pageEditor(
            persistedLargePreviewFileName: "persisted.jpg",
            workingPreviewImage: image,
            workingPreviewID: "working-request",
            aspectRatio: 0.72,
            isGeneratingWorkingPreview: false
        )

        XCTAssertEqual(
            state,
            .memoryImage(id: "working-request", image: image, aspectRatio: 0.72)
        )
    }

    func testPageEditorShowsLoadingWhileWorkingPreviewIsGenerating() {
        let state = PreviewDisplayState.pageEditor(
            persistedLargePreviewFileName: "persisted.jpg",
            workingPreviewImage: nil,
            workingPreviewID: nil,
            aspectRatio: 0.72,
            isGeneratingWorkingPreview: true
        )

        XCTAssertEqual(state, .loading(aspectRatio: 0.72))
    }

    func testPageEditorFallsBackToPersistedPreview() {
        let state = PreviewDisplayState.pageEditor(
            persistedLargePreviewFileName: "persisted.jpg",
            workingPreviewImage: nil,
            workingPreviewID: nil,
            aspectRatio: 0.72,
            isGeneratingWorkingPreview: false
        )

        XCTAssertEqual(
            state,
            .image(fileName: "persisted.jpg", kind: .large, aspectRatio: 0.72)
        )
    }
}
