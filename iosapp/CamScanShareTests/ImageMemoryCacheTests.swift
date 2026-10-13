import UIKit
import XCTest
@testable import CamScanShare

final class ImageMemoryCacheTests: XCTestCase {
    func testByteBudgetEvictsLeastRecentlyUsedImage() {
        let image = makeImage()
        let cost = image.cgImage!.bytesPerRow * image.cgImage!.height
        let cache = ImageMemoryCache(byteLimit: cost * 2, countLimit: 10)
        cache.insert(image, forKey: "first")
        cache.insert(makeImage(), forKey: "second")
        XCTAssertNotNil(cache.image(forKey: "first"))
        cache.insert(makeImage(), forKey: "third")

        XCTAssertNotNil(cache.image(forKey: "first"))
        XCTAssertNil(cache.image(forKey: "second"))
        XCTAssertNotNil(cache.image(forKey: "third"))
    }

    func testOversizedImageIsNotRetained() {
        let cache = ImageMemoryCache(byteLimit: 1, countLimit: 10)
        cache.insert(makeImage(), forKey: "oversized")
        XCTAssertNil(cache.image(forKey: "oversized"))
    }

    func testEvictionAndMemoryWarningReleaseImages() {
        let cache = ImageMemoryCache(byteLimit: 1024 * 1024, countLimit: 1)
        weak var first: UIImage?
        weak var second: UIImage?
        autoreleasepool {
            let image = makeImage()
            first = image
            cache.insert(image, forKey: "first")
        }
        XCTAssertNotNil(first)
        autoreleasepool {
            let image = makeImage()
            second = image
            cache.insert(image, forKey: "second")
        }
        XCTAssertNil(first)
        XCTAssertNotNil(second)

        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(second)
        XCTAssertNil(cache.image(forKey: "second"))
    }

    private func makeImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image {
            UIColor.white.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
    }
}
