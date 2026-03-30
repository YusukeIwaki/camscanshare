import UIKit

extension UIImage {
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func rotated(by degrees: Int) -> UIImage? {
        let normalizedDegrees = ((degrees % 360) + 360) % 360
        guard normalizedDegrees != 0 else { return self }

        let radians = CGFloat(normalizedDegrees) * .pi / 180.0
        var newSize: CGSize
        if normalizedDegrees == 90 || normalizedDegrees == 270 {
            newSize = CGSize(width: size.height, height: size.width)
        } else {
            newSize = size
        }

        UIGraphicsBeginImageContextWithOptions(newSize, false, scale)
        defer { UIGraphicsEndImageContext() }

        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        context.rotate(by: radians)
        draw(in: CGRect(
            x: -size.width / 2, y: -size.height / 2,
            width: size.width, height: size.height))

        return UIGraphicsGetImageFromCurrentImageContext()
    }
}
