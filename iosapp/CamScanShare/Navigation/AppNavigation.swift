import SwiftData
import SwiftUI

enum AppRoute: Hashable {
    case pageList(documentId: PersistentIdentifier)
    case cameraScan(documentId: PersistentIdentifier?, retakePageId: PersistentIdentifier? = nil)
    case pageEdit(documentId: PersistentIdentifier, initialPageIndex: Int)
}

struct AppNavigation: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            DocumentListView(path: $path)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .pageList(let documentId):
                        PageListView(documentId: documentId, path: $path)
                    case .cameraScan(let documentId, let retakePageId):
                        CameraScanView(
                            existingDocumentId: documentId,
                            retakePageId: retakePageId,
                            path: $path
                        )
                    case .pageEdit(let documentId, let initialPageIndex):
                        PageEditView(
                            documentId: documentId, initialPageIndex: initialPageIndex, path: $path)
                    }
                }
        }
    }
}
