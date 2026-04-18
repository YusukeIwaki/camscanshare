import CoreGraphics
import UIKit
import XCTest
@testable import CamScanShare

final class PaperDetectionServiceTests: XCTestCase {
    private func sampleImage(named name: String) -> UIImage {
        let fileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let imageURL = repoRoot
            .appendingPathComponent("docs/public/algorithm/user-samples")
            .appendingPathComponent(name)

        guard let image = UIImage(contentsOfFile: imageURL.path) else {
            XCTFail("Missing fixture: \(imageURL.path)")
            return UIImage()
        }
        return image
    }

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

    func testDetectRectanglePrefersStoreFlyerOverFloorTile() {
        let image = sampleImage(named: "store-flyer-floor-source.png")

        guard let rectangle = PaperDetectionService.detectRectangle(in: image) else {
            XCTFail("Expected store flyer to be detected")
            return
        }

        let minX = min(rectangle.topLeft.x, rectangle.bottomLeft.x)
        let maxX = max(rectangle.topRight.x, rectangle.bottomRight.x)
        let minY = min(rectangle.topLeft.y, rectangle.topRight.y)
        let maxY = max(rectangle.bottomLeft.y, rectangle.bottomRight.y)
        let width = maxX - minX
        let height = maxY - minY

        XCTAssertLessThan(minX, 0.15)
        XCTAssertGreaterThan(maxX, 0.70)
        XCTAssertLessThan(minY, 0.40)
        XCTAssertGreaterThan(maxY, 0.72)
        XCTAssertGreaterThan(width * height, 0.20)
        XCTAssertGreaterThan(height, width * 0.45)
    }
}
