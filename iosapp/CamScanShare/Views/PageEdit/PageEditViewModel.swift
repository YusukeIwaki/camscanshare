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
    var isApplying = false

    private var savedStates: [PageEditState] = []
    private var loadedDocumentId: PersistentIdentifier?
    private var regeneratingPageIDs: Set<PersistentIdentifier> = []

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

    var currentSavedState: PageEditState? {
        guard currentPageIndex >= 0, currentPageIndex < savedStates.count else { return nil }
        return savedStates[currentPageIndex]
    }

    var currentPage: Page? {
        guard currentPageIndex >= 0, currentPageIndex < pages.count else { return nil }
        return pages[currentPageIndex]
    }

    var currentPreviewRequestKey: String {
        let pageKey = currentPage.map { $0.originalImageFileName } ?? "missing"
        let editKey = currentEditState.map { "\($0.filterPreset.rawValue)|\($0.rotationDegrees)" } ?? "missing"
        let savedKey = currentSavedState.map { "\($0.filterPreset.rawValue)|\($0.rotationDegrees)" } ?? "missing"
        return "\(pageKey)|\(editKey)|\(savedKey)|\(currentPageIndex)"
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

    func apply(
        context: ModelContext,
        currentWorkingPreviewImage: UIImage? = nil,
        currentWorkingPreviewRequestKey: String? = nil
    ) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let sorted = document?.sortedPages ?? []
        for (index, page) in sorted.enumerated() {
            guard index < editStates.count else { break }
            let newState = editStates[index]
            let oldState = index < savedStates.count ? savedStates[index] : nil
            page.filterPreset = newState.filterPreset
            page.rotationDegrees = newState.rotationDegrees

            if oldState != newState || pageNeedsPreviewRegeneration(page) {
                let previewRequestKey =
                    "\(page.originalImageFileName)|\(newState.filterPreset.rawValue)|\(newState.rotationDegrees)"
                let renderedPreviewImage =
                    currentWorkingPreviewRequestKey == previewRequestKey ? currentWorkingPreviewImage : nil
                await reconcilePersistedPreviews(
                    for: page,
                    context: context,
                    force: true,
                    renderedPreviewImage: renderedPreviewImage
                )
            }

            WorkingPreviewStorageService.deleteWorkingPreviews(sourceFileName: page.originalImageFileName)
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

    func editState(at index: Int) -> PageEditState? {
        guard index >= 0, index < editStates.count else { return nil }
        return editStates[index]
    }

    func savedState(at index: Int) -> PageEditState? {
        guard index >= 0, index < savedStates.count else { return nil }
        return savedStates[index]
    }

    func ensurePersistedPreview(for page: Page, context: ModelContext) {
        let pageID = page.persistentModelID
        guard pageNeedsPreviewRegeneration(page) else { return }
        guard regeneratingPageIDs.insert(pageID).inserted else { return }

        Task { @MainActor [weak self] in
            await reconcilePersistedPreviews(for: page, context: context)
            self?.regeneratingPageIDs.remove(pageID)
        }
    }

    func isRegeneratingPersistedPreview(for page: Page?) -> Bool {
        guard let page else { return false }
        return regeneratingPageIDs.contains(page.persistentModelID)
    }
}
