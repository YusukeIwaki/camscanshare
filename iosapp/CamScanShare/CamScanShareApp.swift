import SwiftData
import SwiftUI

@main
struct CamScanShareApp: App {
    var body: some Scene {
        WindowGroup {
            AppNavigation()
        }
        .modelContainer(for: [Document.self, Page.self])
    }
}
