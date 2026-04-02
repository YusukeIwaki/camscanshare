import CoreGraphics
import UIKit

enum PreviewDisplayState {
    case image(fileName: String, kind: PreviewImageKind, aspectRatio: CGFloat)
    case memoryImage(id: String, image: UIImage, aspectRatio: CGFloat)
    case loading(aspectRatio: CGFloat)
    case placeholder(aspectRatio: CGFloat)

    static func pageCard(
        largePreviewFileName: String?,
        aspectRatio: CGFloat,
        isRegenerating: Bool
    ) -> PreviewDisplayState {
        if let largePreviewFileName {
            return .image(fileName: largePreviewFileName, kind: .large, aspectRatio: aspectRatio)
        }
        return isRegenerating ? .loading(aspectRatio: aspectRatio) : .placeholder(aspectRatio: aspectRatio)
    }

    static func pageEditor(
        persistedLargePreviewFileName: String?,
        workingPreviewImage: UIImage?,
        workingPreviewID: String?,
        aspectRatio: CGFloat,
        isGeneratingWorkingPreview: Bool
    ) -> PreviewDisplayState {
        if let workingPreviewImage, let workingPreviewID {
            return .memoryImage(id: workingPreviewID, image: workingPreviewImage, aspectRatio: aspectRatio)
        }
        if isGeneratingWorkingPreview {
            return .loading(aspectRatio: aspectRatio)
        }
        if let persistedLargePreviewFileName {
            return .image(fileName: persistedLargePreviewFileName, kind: .large, aspectRatio: aspectRatio)
        }
        return .placeholder(aspectRatio: aspectRatio)
    }
}

extension PreviewDisplayState: Equatable {
    static func == (lhs: PreviewDisplayState, rhs: PreviewDisplayState) -> Bool {
        switch (lhs, rhs) {
        case let (.image(lhsFileName, lhsKind, lhsAspectRatio), .image(rhsFileName, rhsKind, rhsAspectRatio)):
            return lhsFileName == rhsFileName
                && lhsKind == rhsKind
                && lhsAspectRatio == rhsAspectRatio
        case let (.memoryImage(lhsID, _, lhsAspectRatio), .memoryImage(rhsID, _, rhsAspectRatio)):
            return lhsID == rhsID && lhsAspectRatio == rhsAspectRatio
        case let (.loading(lhsAspectRatio), .loading(rhsAspectRatio)):
            return lhsAspectRatio == rhsAspectRatio
        case let (.placeholder(lhsAspectRatio), .placeholder(rhsAspectRatio)):
            return lhsAspectRatio == rhsAspectRatio
        default:
            return false
        }
    }
}
