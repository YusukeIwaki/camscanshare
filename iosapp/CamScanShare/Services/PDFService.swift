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
    static let a4PortraitWidth: CGFloat = 595.28
    static let a4PortraitHeight: CGFloat = 841.89
    static let a4PortraitAspectRatio: CGFloat = a4PortraitWidth / a4PortraitHeight
    static let a4LandscapeAspectRatio: CGFloat = a4PortraitHeight / a4PortraitWidth
    private static let a4SnapTolerance: CGFloat = 0.2
    private static let defaultPageRect = CGRect(
        x: 0,
        y: 0,
        width: a4PortraitWidth,
        height: a4PortraitHeight
    )

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

        let renderer = UIGraphicsPDFRenderer(bounds: defaultPageRect)

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

                let pageRect = pageRect(for: filteredImage.size)
                pdfContext.beginPage(withBounds: pageRect, pageInfo: [:])

                let imageSize = filteredImage.size
                let widthRatio = pageRect.width / imageSize.width
                let heightRatio = pageRect.height / imageSize.height
                let scale = min(widthRatio, heightRatio)

                let scaledWidth = imageSize.width * scale
                let scaledHeight = imageSize.height * scale
                let x = (pageRect.width - scaledWidth) / 2
                let y = (pageRect.height - scaledHeight) / 2

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

    static func pageRect(for imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return defaultPageRect
        }

        let aspectRatio = pageAspectRatio(for: imageSize)

        if relativeDifference(actual: aspectRatio, expected: a4PortraitAspectRatio) <= a4SnapTolerance {
            return CGRect(x: 0, y: 0, width: a4PortraitWidth, height: a4PortraitHeight)
        }

        if relativeDifference(actual: aspectRatio, expected: a4LandscapeAspectRatio) <= a4SnapTolerance {
            return CGRect(x: 0, y: 0, width: a4PortraitHeight, height: a4PortraitWidth)
        }

        if aspectRatio >= 1 {
            let width = a4PortraitHeight
            let height = width / aspectRatio
            return CGRect(x: 0, y: 0, width: width, height: height)
        }

        let height = a4PortraitHeight
        let width = height * aspectRatio
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    private static func pageAspectRatio(for imageSize: CGSize) -> CGFloat {
        imageSize.width / imageSize.height
    }

    private static func relativeDifference(actual: CGFloat, expected: CGFloat) -> CGFloat {
        abs(actual - expected) / expected
    }
}
