import SwiftData
import SwiftUI

struct PageEditState: Equatable {
    var filterPreset: FilterPreset
    var rotationDegrees: Int
}

@MainActor @Observable
final class PageEditViewModel {
    var document: Document?
    var currentPageIndex: Int = 0
    var editStates: [PageEditState] = []
    var showFilterPanel = false
    var showDiscardDialog = false
    var showApplyAllFilterDialog = false
    var pendingApplyAllFilter: FilterPreset?

    private var savedStates: [PageEditState] = []
    private var loadedDocumentId: PersistentIdentifier?

    var pages: [Page] {
        document?.sortedPages ?? []
    }

    var totalPages: Int {
        pages.count
    }

    var currentEditState: PageEditState? {
        guard currentPageIndex >= 0, currentPageIndex < editStates.count else { return nil }
        return editStates[currentPageIndex]
    }

    var isDirty: Bool {
        editStates != savedStates
    }

    func loadDocument(id: PersistentIdentifier, initialPageIndex: Int, context: ModelContext) {
        if loadedDocumentId == id, document != nil {
            currentPageIndex = min(currentPageIndex, max(editStates.count - 1, 0))
            return
        }

        document = context.model(for: id) as? Document
        loadedDocumentId = id
        currentPageIndex = initialPageIndex

        let sorted = document?.sortedPages ?? []
        editStates = sorted.map {
            PageEditState(filterPreset: $0.filterPreset, rotationDegrees: $0.rotationDegrees)
        }
        savedStates = editStates
        currentPageIndex = min(initialPageIndex, max(editStates.count - 1, 0))
    }

    func rotateCurrentPage() {
        guard currentPageIndex < editStates.count else { return }
        editStates[currentPageIndex].rotationDegrees =
            (editStates[currentPageIndex].rotationDegrees - 90 + 360) % 360
    }

    func setFilter(_ filter: FilterPreset, forCurrentPage: Bool = true) {
        guard forCurrentPage else { return }
        guard currentPageIndex < editStates.count else { return }
        editStates[currentPageIndex].filterPreset = filter
    }

    func setFilterForAllPages(_ filter: FilterPreset) {
        for index in editStates.indices {
            editStates[index].filterPreset = filter
        }
    }

    func apply(context: ModelContext) {
        let sorted = document?.sortedPages ?? []
        for (index, page) in sorted.enumerated() {
            guard index < editStates.count else { break }
            page.filterPreset = editStates[index].filterPreset
            page.rotationDegrees = editStates[index].rotationDegrees
        }
        document?.updatedAt = .now
        try? context.save()
        savedStates = editStates
    }

    func discardChanges() {
        editStates = savedStates
    }

    var currentPageId: PersistentIdentifier? {
        guard currentPageIndex >= 0, currentPageIndex < pages.count else { return nil }
        return pages[currentPageIndex].persistentModelID
    }
}
