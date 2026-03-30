import SwiftData
import SwiftUI

@MainActor @Observable
final class PageListViewModel {
    var document: Document?
    var showRenameDialog = false
    var renameText = ""
    var isGeneratingPDF = false
    var pdfURL: URL?
    var showShareSheet = false

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
        ImageStorageService.deleteImage(fileName: page.originalImageFileName)
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

        let pageData = document.sortedPages.map { page in
            PDFPageData(
                imageFileName: page.originalImageFileName,
                filterPreset: page.filterPreset,
                rotationDegrees: page.rotationDegrees
            )
        }
        let documentName = document.name

        Task {
            let generatedURL = await Task.detached(priority: .userInitiated) {
                PDFService.generatePDF(from: pageData, fileName: documentName)
            }.value
            pdfURL = generatedURL
            isGeneratingPDF = false
            if generatedURL != nil {
                showShareSheet = true
            }
        }
    }
}
