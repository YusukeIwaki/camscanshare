import UIKit

struct PDFPageData: Sendable, Equatable {
    let imageFileName: String
    let smallPreviewFileName: String?
    let largePreviewFileName: String?
    let filterPreset: FilterPreset
    let rotationDegrees: Int
}

enum PDFGenerationPhase: Sendable, Equatable {
    case preparing
    case renderingPage
    case finalizing
}

struct PDFGenerationProgress: Sendable, Equatable {
    let phase: PDFGenerationPhase
    let currentPage: Int
    let totalPages: Int
    let currentPageData: PDFPageData?

    var title: String {
        "PDFを作成中"
    }

    var detailText: String {
        switch phase {
        case .preparing:
            if totalPages > 0 {
                return "\(totalPages)ページのPDFを準備中…"
            }
            return "PDFを準備中…"
        case .renderingPage:
            guard totalPages > 0 else { return "ページを処理中…" }
            guard let currentPageData else {
                return "\(currentPage) / \(totalPages)ページを処理中…"
            }
            if currentPageData.filterPreset == .original {
                return "\(currentPage) / \(totalPages)ページを処理中…"
            }
            return "\(currentPage) / \(totalPages)ページを\(currentPageData.filterPreset.displayName)で処理中…"
        case .finalizing:
            if totalPages > 0 {
                return "\(totalPages)ページのPDFを書き出し中…"
            }
            return "PDFを書き出し中…"
        }
    }

    var fractionCompleted: Double? {
        guard totalPages > 0 else { return nil }
        switch phase {
        case .preparing:
            return 0
        case .renderingPage:
            return min(max(Double(currentPage) / Double(totalPages), 0), 1)
        case .finalizing:
            return 1
        }
    }
}

enum PDFService {
    // A4 size in points (72 dpi)
    private static let a4Width: CGFloat = 595.28
    private static let a4Height: CGFloat = 841.89

    static func generatePDF(
        from pages: [PDFPageData],
        fileName: String,
        progressHandler: @Sendable (PDFGenerationProgress) -> Void = { _ in }
    ) -> URL? {
        let safeName = fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent((safeName.isEmpty ? UUID().uuidString : safeName) + ".pdf")

        let pageRect = CGRect(x: 0, y: 0, width: a4Width, height: a4Height)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        progressHandler(
            PDFGenerationProgress(
                phase: .preparing,
                currentPage: 0,
                totalPages: pages.count,
                currentPageData: pages.first
            )
        )

        let data = renderer.pdfData { pdfContext in
            for (index, page) in pages.enumerated() {
                progressHandler(
                    PDFGenerationProgress(
                        phase: .renderingPage,
                        currentPage: index + 1,
                        totalPages: pages.count,
                        currentPageData: page
                    )
                )

                guard let originalImage = ImageStorageService.loadImage(fileName: page.imageFileName)
                else { continue }

                guard let filteredImage = ImageFilterService.applyFilter(
                    page.filterPreset,
                    to: originalImage,
                    rotation: page.rotationDegrees,
                    intent: .export
                )
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

        progressHandler(
            PDFGenerationProgress(
                phase: .finalizing,
                currentPage: pages.count,
                totalPages: pages.count,
                currentPageData: pages.last
            )
        )

        do {
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }
}
