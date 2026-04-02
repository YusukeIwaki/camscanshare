import SwiftData
import SwiftUI

@main
struct CamScanShareApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema(versionedSchema: SchemaV2.self)
        return try! ModelContainer(for: schema, migrationPlan: CamScanShareMigrationPlan.self)
    }()

    init() {
        WorkingPreviewStorageService.deleteAllWorkingPreviews()
    }

    var body: some Scene {
        WindowGroup {
            AppNavigation()
        }
        .modelContainer(modelContainer)
    }
}
