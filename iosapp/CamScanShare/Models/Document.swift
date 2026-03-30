import Foundation
import SwiftData

@Model
final class Document {
    private static let defaultNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var name: String
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Page.document)
    var pages: [Page] = []

    init(name: String? = nil) {
        self.name = name ?? "スキャン \(Self.defaultNameFormatter.string(from: .now))"
        self.createdAt = .now
        self.updatedAt = .now
    }

    var sortedPages: [Page] {
        pages.sorted { $0.sortOrder < $1.sortOrder }
    }
}
