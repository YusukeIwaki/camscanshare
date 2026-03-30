import SwiftUI

struct DetectionOverlayView: View {
    let rectangle: DetectedRectangle?
    let previewSize: CGSize
    let imageAspectRatio: CGFloat

    var body: some View {
        Canvas { context, size in
            guard let rect = rectangle else { return }

            // Convert normalized Vision coordinates (bottom-left origin, 0-1) to view coordinates
            let tl = convertPoint(rect.topLeft, in: size)
            let tr = convertPoint(rect.topRight, in: size)
            let bl = convertPoint(rect.bottomLeft, in: size)
            let br = convertPoint(rect.bottomRight, in: size)

            // Fill
            var fillPath = Path()
            fillPath.move(to: tl)
            fillPath.addLine(to: tr)
            fillPath.addLine(to: br)
            fillPath.addLine(to: bl)
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(.blue.opacity(0.06)))

            // Edges
            var edgePath = Path()
            edgePath.move(to: tl)
            edgePath.addLine(to: tr)
            edgePath.addLine(to: br)
            edgePath.addLine(to: bl)
            edgePath.closeSubpath()
            context.stroke(edgePath, with: .color(.blue.opacity(0.4)), lineWidth: 2)

            // Corners
            let cornerLength: CGFloat = 24
            drawCorner(context: context, point: tl, dir1: tr, dir2: bl, length: cornerLength)
            drawCorner(context: context, point: tr, dir1: tl, dir2: br, length: cornerLength)
            drawCorner(context: context, point: bl, dir1: tl, dir2: br, length: cornerLength)
            drawCorner(context: context, point: br, dir1: bl, dir2: tr, length: cornerLength)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.15), value: rectangle?.topLeft.x)
    }

    private func convertPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let viewAspectRatio = size.width / size.height

        if imageAspectRatio > viewAspectRatio {
            let scaledWidth = size.height * imageAspectRatio
            let offsetX = (scaledWidth - size.width) / 2
            return CGPoint(
                x: point.x * scaledWidth - offsetX,
                y: (1 - point.y) * size.height
            )
        } else {
            let scaledHeight = size.width / imageAspectRatio
            let offsetY = (scaledHeight - size.height) / 2
            return CGPoint(
                x: point.x * size.width,
                y: (1 - point.y) * scaledHeight - offsetY
            )
        }
    }

    private func drawCorner(
        context: GraphicsContext, point: CGPoint, dir1: CGPoint, dir2: CGPoint, length: CGFloat
    ) {
        let toDir1 = unitVector(from: point, to: dir1)
        let toDir2 = unitVector(from: point, to: dir2)

        var path = Path()
        path.move(to: CGPoint(x: point.x + toDir1.x * length, y: point.y + toDir1.y * length))
        path.addLine(to: point)
        path.addLine(to: CGPoint(x: point.x + toDir2.x * length, y: point.y + toDir2.y * length))

        context.stroke(path, with: .color(.blue), lineWidth: 3)
    }

    private func unitVector(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 0 else { return .zero }
        return CGPoint(x: dx / len, y: dy / len)
    }
}
