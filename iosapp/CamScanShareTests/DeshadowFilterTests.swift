import UIKit
import XCTest

@testable import CamScanShare

final class DeshadowFilterTests: XCTestCase {
    private func makeTestImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size, format: .init(for: .init(displayScale: 1)))
        return renderer.image { context in
            UIColor(white: 0.92, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // diagonal shadow band
            UIColor(white: 0.6, alpha: 1).setFill()
            context.cgContext.move(to: .zero)
            context.cgContext.addLine(to: CGPoint(x: size.width * 0.5, y: 0))
            context.cgContext.addLine(to: CGPoint(x: 0, y: size.height * 0.5))
            context.cgContext.closePath()
            context.cgContext.fillPath()
            // text-like dark lines
            UIColor.black.setFill()
            for row in 0..<6 {
                context.fill(CGRect(x: 20, y: 40 + row * 30, width: width - 40, height: 6))
            }
        }
    }

    func testDeshadowFilterProducesSameSizeOutput() throws {
        let input = makeTestImage(width: 600, height: 800)
        let output = ImageFilterService.applyFilter(.deshadow, to: input, intent: .export)
        let result = try XCTUnwrap(output, "deshadow filter should produce an output image")
        XCTAssertEqual(Int(result.size.width), 600)
        XCTAssertEqual(Int(result.size.height), 800)
    }

    func testDeshadowFilterBrightensShadowRegion() throws {
        let input = makeTestImage(width: 512, height: 512)
        let output = try XCTUnwrap(ImageFilterService.applyFilter(.deshadow, to: input, intent: .export))

        func meanLuminance(_ image: UIImage, in rect: CGRect) throws -> Double {
            let cgImage = try XCTUnwrap(image.cgImage?.cropping(to: rect))
            let width = cgImage.width
            let height = cgImage.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            var sum = 0.0
            for index in stride(from: 0, to: pixels.count, by: 4) {
                sum += (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3.0
            }
            return sum / Double(width * height)
        }

        // sample inside the shadow triangle but away from text lines
        let shadowRect = CGRect(x: 8, y: 8, width: 24, height: 24)
        let before = try meanLuminance(input, in: shadowRect)
        let after = try meanLuminance(output, in: shadowRect)
        XCTAssertGreaterThan(after, before + 10, "shadow region should be substantially brightened")
    }
}
