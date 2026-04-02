import SwiftData
import SwiftUI

@MainActor @Observable
final class PageListViewModel {
    var document: Document?
    var showRenameDialog = false
    var showPDFErrorAlert = false
    var renameText = ""
    var isGeneratingPDF = false
    var pdfGenerationProgress: PDFGenerationProgress?
    var pdfURL: URL?
    var showShareSheet = false
    private var regeneratingPageIDs: Set<PersistentIdentifier> = []

    func loadDocument(id: PersistentIdentifier, context: ModelContext) {
        document = context.model(for: id) as? Document
        renameText = document?.name ?? ""
    }

    var sortedPages: [Page] {
        document?.sortedPages ?? []
    }

    func rename(context: ModelContext) {
        guard let document, !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        document.name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        document.updatedAt = .now
        try? context.save()
    }

    func movePage(from source: Int, to destination: Int, context: ModelContext) {
        guard let document else { return }
        var pages = document.sortedPages
        guard source >= 0, source < pages.count, destination >= 0, destination < pages.count else { return }
        guard source != destination else { return }

        let page = pages.remove(at: source)
        pages.insert(page, at: destination)

        for (index, p) in pages.enumerated() {
            p.sortOrder = index
        }
        document.updatedAt = .now
        try? context.save()
    }

    func reorderPages(_ pageIDs: [PersistentIdentifier], context: ModelContext) {
        guard let document else { return }
        let pagesByID = Dictionary(uniqueKeysWithValues: document.pages.map { ($0.persistentModelID, $0) })

        for (index, pageID) in pageIDs.enumerated() {
            pagesByID[pageID]?.sortOrder = index
        }

        document.updatedAt = .now
        try? context.save()
    }

    func deletePage(_ page: Page, context: ModelContext) {
        deletePageAssets(page)
        context.delete(page)
        let remainingPages = sortedPages.filter { $0.persistentModelID != page.persistentModelID }
        for (index, remainingPage) in remainingPages.enumerated() {
            remainingPage.sortOrder = index
        }
        document?.updatedAt = .now
        try? context.save()
    }

    func generateAndSharePDF() {
        guard let document else { return }
        isGeneratingPDF = true
        showPDFErrorAlert = false

        let pageData = document.sortedPages.map { page in
            PDFPageData(
                imageFileName: page.originalImageFileName,
                smallPreviewFileName: page.smallPreviewFileName,
                largePreviewFileName: page.largePreviewFileName,
                filterPreset: page.filterPreset,
                rotationDegrees: page.rotationDegrees
            )
        }
        let documentName = document.name
        pdfGenerationProgress = PDFGenerationProgress(
            phase: .preparing,
            currentPage: 0,
            totalPages: pageData.count,
            currentPageData: pageData.first
        )

        var progressContinuation: AsyncStream<PDFGenerationProgress>.Continuation?
        let progressStream = AsyncStream(PDFGenerationProgress.self) { continuation in
            progressContinuation = continuation
        }

        Task { [weak self, pageData, documentName] in
            let progressTask = Task { @MainActor [weak self] in
                for await progress in progressStream {
                    self?.pdfGenerationProgress = progress
                }
            }

            let generatedURL = await Task.detached(priority: .userInitiated) {
                guard let progressContinuation else {
                    return PDFService.generatePDF(from: pageData, fileName: documentName)
                }
                return PDFService.generatePDF(
                    from: pageData,
                    fileName: documentName,
                    progressHandler: { progress in
                        progressContinuation.yield(progress)
                    }
                )
            }.value
            guard let self else { return }

            if let progressContinuation {
                progressContinuation.finish()
            }
            _ = await progressTask.result

            pdfURL = generatedURL
            isGeneratingPDF = false
            pdfGenerationProgress = nil
            if generatedURL != nil {
                showShareSheet = true
            } else {
                showPDFErrorAlert = true
            }
        }
    }

    func ensureLargePreview(for page: Page, context: ModelContext) {
        let pageID = page.persistentModelID
        guard pageNeedsPreviewRegeneration(page) else { return }
        guard regeneratingPageIDs.insert(pageID).inserted else { return }

        Task { @MainActor [weak self] in
            await reconcilePersistedPreviews(for: page, context: context)
            self?.regeneratingPageIDs.remove(pageID)
        }
    }

    func isRegeneratingPreview(for page: Page) -> Bool {
        regeneratingPageIDs.contains(page.persistentModelID)
    }
}
