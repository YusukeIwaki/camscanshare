import Foundation
import SwiftData

enum SchemaV1: VersionedSchema {
    static let versionIdentifier: Schema.Version = .init(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SchemaV1.Document.self,
            SchemaV1.Page.self,
        ]
    }

    @Model
    final class Document {
        var name: String
        var createdAt: Date
        var updatedAt: Date

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.Page.document)
        var pages: [SchemaV1.Page] = []

        init(name: String, createdAt: Date, updatedAt: Date) {
            self.name = name
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    @Model
    final class Page {
        var document: SchemaV1.Document?
        var sortOrder: Int
        var originalImageFileName: String
        var filterName: String
        var rotationDegrees: Int

        init(
            document: SchemaV1.Document? = nil,
            sortOrder: Int,
            originalImageFileName: String,
            filterName: String,
            rotationDegrees: Int
        ) {
            self.document = document
            self.sortOrder = sortOrder
            self.originalImageFileName = originalImageFileName
            self.filterName = filterName
            self.rotationDegrees = rotationDegrees
        }
    }
}

enum SchemaV2: VersionedSchema {
    static let versionIdentifier: Schema.Version = .init(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SchemaV2.Document.self,
            SchemaV2.Page.self,
        ]
    }

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

        @Relationship(deleteRule: .cascade, inverse: \SchemaV2.Page.document)
        var pages: [SchemaV2.Page] = []

        init(name: String? = nil) {
            self.name = name ?? "スキャン \(Self.defaultNameFormatter.string(from: .now))"
            self.createdAt = .now
            self.updatedAt = .now
        }

        var sortedPages: [SchemaV2.Page] {
            pages.sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    @Model
    final class Page {
        var document: SchemaV2.Document?
        var sortOrder: Int
        var originalImageFileName: String
        var filterName: String
        var rotationDegrees: Int
        var smallPreviewFileName: String?
        var largePreviewFileName: String?

        init(
            document: SchemaV2.Document,
            sortOrder: Int,
            originalImageFileName: String,
            smallPreviewFileName: String? = nil,
            largePreviewFileName: String? = nil
        ) {
            self.document = document
            self.sortOrder = sortOrder
            self.originalImageFileName = originalImageFileName
            self.filterName = FilterPreset.original.rawValue
            self.rotationDegrees = 0
            self.smallPreviewFileName = smallPreviewFileName
            self.largePreviewFileName = largePreviewFileName
        }

        var filterPreset: FilterPreset {
            get { FilterPreset(rawValue: filterName) ?? .original }
            set { filterName = newValue.rawValue }
        }
    }
}

enum SchemaV3: VersionedSchema {
    static let versionIdentifier: Schema.Version = .init(3, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SchemaV3.Document.self,
            SchemaV3.Page.self,
        ]
    }

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

        @Relationship(deleteRule: .cascade, inverse: \SchemaV3.Page.document)
        var pages: [SchemaV3.Page] = []

        init(name: String? = nil) {
            self.name = name ?? "スキャン \(Self.defaultNameFormatter.string(from: .now))"
            self.createdAt = .now
            self.updatedAt = .now
        }

        var sortedPages: [SchemaV3.Page] {
            pages.sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    @Model
    final class Page {
        var document: SchemaV3.Document?
        var sortOrder: Int
        var originalImageFileName: String
        var filterName: String
        var rotationDegrees: Int
        var smallPreviewFileName: String?
        var largePreviewFileName: String?
        var isDebugCapture: Bool = false

        init(
            document: SchemaV3.Document,
            sortOrder: Int,
            originalImageFileName: String,
            smallPreviewFileName: String? = nil,
            largePreviewFileName: String? = nil,
            isDebugCapture: Bool = false
        ) {
            self.document = document
            self.sortOrder = sortOrder
            self.originalImageFileName = originalImageFileName
            self.filterName = FilterPreset.original.rawValue
            self.rotationDegrees = 0
            self.smallPreviewFileName = smallPreviewFileName
            self.largePreviewFileName = largePreviewFileName
            self.isDebugCapture = isDebugCapture
        }

        var filterPreset: FilterPreset {
            get { FilterPreset(rawValue: filterName) ?? .original }
            set { filterName = newValue.rawValue }
        }
    }
}

enum SchemaV4: VersionedSchema {
    static let versionIdentifier: Schema.Version = .init(4, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            SchemaV4.Document.self,
            SchemaV4.Page.self,
        ]
    }

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

        @Relationship(deleteRule: .cascade, inverse: \SchemaV4.Page.document)
        var pages: [SchemaV4.Page] = []

        init(name: String? = nil) {
            self.name = name ?? "スキャン \(Self.defaultNameFormatter.string(from: .now))"
            self.createdAt = .now
            self.updatedAt = .now
        }

        var sortedPages: [SchemaV4.Page] {
            pages.sorted { $0.sortOrder < $1.sortOrder }
        }
    }

    @Model
    final class Page {
        var document: SchemaV4.Document?
        var sortOrder: Int
        var originalImageFileName: String
        var filterName: String
        var rotationDegrees: Int
        var smallPreviewFileName: String?
        var largePreviewFileName: String?
        var isDebugCapture: Bool = false
        var debugCaptureId: String?

        init(
            document: SchemaV4.Document,
            sortOrder: Int,
            originalImageFileName: String,
            smallPreviewFileName: String? = nil,
            largePreviewFileName: String? = nil,
            isDebugCapture: Bool = false,
            debugCaptureId: String? = nil
        ) {
            self.document = document
            self.sortOrder = sortOrder
            self.originalImageFileName = originalImageFileName
            self.filterName = FilterPreset.original.rawValue
            self.rotationDegrees = 0
            self.smallPreviewFileName = smallPreviewFileName
            self.largePreviewFileName = largePreviewFileName
            self.isDebugCapture = isDebugCapture
            self.debugCaptureId = debugCaptureId
        }

        var filterPreset: FilterPreset {
            get { FilterPreset(rawValue: filterName) ?? .original }
            set { filterName = newValue.rawValue }
        }
    }
}

enum CamScanShareMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [
            SchemaV1.self,
            SchemaV2.self,
            SchemaV3.self,
            SchemaV4.self,
        ]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self),
            .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
            .lightweight(fromVersion: SchemaV3.self, toVersion: SchemaV4.self),
        ]
    }
}
