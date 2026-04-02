import Foundation
import SwiftData
import SwiftUI

@MainActor @Observable
final class DocumentListViewModel {
    var selectedIds: Set<PersistentIdentifier> = []
    var isSelectionMode = false
    var showDeleteConfirmation = false
    private var regeneratingPageIDs: Set<PersistentIdentifier> = []

    func enterSelectionMode(with id: PersistentIdentifier) {
        isSelectionMode = true
        selectedIds = [id]
    }

    func toggleSelection(_ id: PersistentIdentifier) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
            if selectedIds.isEmpty {
                isSelectionMode = false
            }
        } else {
            selectedIds.insert(id)
        }
    }

    func exitSelectionMode() {
        isSelectionMode = false
        selectedIds.removeAll()
    }

    func deleteSelected(documents: [Document], modelContext: ModelContext) {
        for document in documents where selectedIds.contains(document.persistentModelID) {
            for page in document.pages {
                deletePageAssets(page)
            }
            modelContext.delete(document)
        }
        try? modelContext.save()
        exitSelectionMode()
    }

    func ensureSmallPreview(for page: Page?, context: ModelContext) {
        guard let page else { return }
        let pageID = page.persistentModelID
        guard pageNeedsPreviewRegeneration(page) else { return }
        guard regeneratingPageIDs.insert(pageID).inserted else { return }

        Task { @MainActor [weak self] in
            await reconcilePersistedPreviews(for: page, context: context)
            self?.regeneratingPageIDs.remove(pageID)
        }
    }

    func isRegeneratingPreview(for page: Page?) -> Bool {
        guard let page else { return false }
        return regeneratingPageIDs.contains(page.persistentModelID)
    }
}
