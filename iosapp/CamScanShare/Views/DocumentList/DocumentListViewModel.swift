import Foundation
import SwiftData
import SwiftUI

@MainActor @Observable
final class DocumentListViewModel {
    var selectedIds: Set<PersistentIdentifier> = []
    var isSelectionMode = false
    var showDeleteConfirmation = false

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
            // Delete associated image files
            for page in document.pages {
                ImageStorageService.deleteImage(fileName: page.originalImageFileName)
            }
            modelContext.delete(document)
        }
        try? modelContext.save()
        exitSelectionMode()
    }
}
