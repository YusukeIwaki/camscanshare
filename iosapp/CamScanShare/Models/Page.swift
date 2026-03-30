import Foundation
import SwiftData

@Model
final class Page {
    var document: Document?
    var sortOrder: Int
    var originalImageFileName: String
    var filterName: String
    var rotationDegrees: Int

    init(document: Document, sortOrder: Int, originalImageFileName: String) {
        self.document = document
        self.sortOrder = sortOrder
        self.originalImageFileName = originalImageFileName
        self.filterName = FilterPreset.magic.rawValue
        self.rotationDegrees = 0
    }

    var filterPreset: FilterPreset {
        get { FilterPreset(rawValue: filterName) ?? .magic }
        set { filterName = newValue.rawValue }
    }
}
