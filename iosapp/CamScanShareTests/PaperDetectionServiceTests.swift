import CoreGraphics
import XCTest
@testable import CamScanShare

final class PaperDetectionServiceTests: XCTestCase {
    func testTargetPaperRatioSelectsPortraitForSymmetricA4() {
        let ratio = PaperDetectionService.targetPaperRatio(
            widthTop: 210,
            widthBottom: 210,
            heightLeft: 297,
            heightRight: 297
        )

        XCTAssertNotNil(ratio)
        XCTAssertEqual(ratio!, 210.0 / 297.0, accuracy: 0.0001)
    }

    func testTargetPaperRatioSelectsLandscapeForSymmetricA4() {
        let ratio = PaperDetectionService.targetPaperRatio(
            widthTop: 297,
            widthBottom: 297,
            heightLeft: 210,
            heightRight: 210
        )

        XCTAssertNotNil(ratio)
        XCTAssertEqual(ratio!, 297.0 / 210.0, accuracy: 0.0001)
    }

    func testTargetPaperRatioKeepsPortraitWhenOnlyBottomEdgeLooksWide() {
        let ratio = PaperDetectionService.targetPaperRatio(
            widthTop: 150,
            widthBottom: 500,
            heightLeft: 350,
            heightRight: 340
        )

        XCTAssertNotNil(ratio)
        XCTAssertEqual(ratio!, 210.0 / 297.0, accuracy: 0.0001)
    }

    func testTargetPaperRatioKeepsLandscapeWhenOnlyRightEdgeLooksTall() {
        let ratio = PaperDetectionService.targetPaperRatio(
            widthTop: 350,
            widthBottom: 340,
            heightLeft: 150,
            heightRight: 500
        )

        XCTAssertNotNil(ratio)
        XCTAssertEqual(ratio!, 297.0 / 210.0, accuracy: 0.0001)
    }

    func testTargetPaperRatioRejectsNonPaperLikeSquare() {
        let ratio = PaperDetectionService.targetPaperRatio(
            widthTop: 250,
            widthBottom: 250,
            heightLeft: 250,
            heightRight: 250
        )

        XCTAssertNil(ratio)
    }

    func testNormalizedSizePreservesAreaAndAppliesPortraitA4Ratio() {
        let originalSize = CGSize(width: 1200, height: 900)
        let normalizedSize = PaperDetectionService.normalizedSize(
            for: originalSize,
            targetRatio: 210.0 / 297.0
        )

        let originalArea = originalSize.width * originalSize.height
        let normalizedArea = normalizedSize.width * normalizedSize.height

        XCTAssertEqual(normalizedSize.width / normalizedSize.height, 210.0 / 297.0, accuracy: 0.001)
        XCTAssertEqual(normalizedArea, originalArea, accuracy: originalArea * 0.001)
        XCTAssertLessThan(normalizedSize.width, normalizedSize.height)
    }
}
