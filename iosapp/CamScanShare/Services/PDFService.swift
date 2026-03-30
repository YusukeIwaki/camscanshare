import UIKit

struct PDFPageData: Sendable {
    let imageFileName: String
    let filterPreset: FilterPreset
    let rotationDegrees: Int
}

enum PDFService {
    // A4 size in points (72 dpi)
    private static let a4Width: CGFloat = 595.28
    private static let a4Height: CGFloat = 841.89

    static func generatePDF(from pages: [PDFPageData], fileName: String) -> URL? {
        let safeName = fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent((safeName.isEmpty ? UUID().uuidString : safeName) + ".pdf")

        let pageRect = CGRect(x: 0, y: 0, width: a4Width, height: a4Height)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let data = renderer.pdfData { pdfContext in
            for page in pages {
                guard let originalImage = ImageStorageService.loadImage(fileName: page.imageFileName)
                else { continue }

                guard let filteredImage = ImageFilterService.applyFilter(
                    page.filterPreset, to: originalImage, rotation: page.rotationDegrees)
                else { continue }

                pdfContext.beginPage()

                let imageSize = filteredImage.size
                let widthRatio = a4Width / imageSize.width
                let heightRatio = a4Height / imageSize.height
                let scale = min(widthRatio, heightRatio)

                let scaledWidth = imageSize.width * scale
                let scaledHeight = imageSize.height * scale
                let x = (a4Width - scaledWidth) / 2
                let y = (a4Height - scaledHeight) / 2

                filteredImage.draw(in: CGRect(x: x, y: y, width: scaledWidth, height: scaledHeight))
            }
        }

        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }
}
