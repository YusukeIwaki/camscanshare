import SwiftUI

@MainActor @Observable
final class WorkingPreviewManager {
    var previewImage: UIImage?
    var previewRequestKey: String?
    var isGenerating = false
    var supportsPersistedReuse = false

    private var activeRequestKey: String?
    private var activeSourceFileName: String?
    private let imageCache = NSCache<NSString, UIImage>()
    private let reusableMaxDimension: CGFloat = 1600

    func updatePreview(
        for page: Page?,
        editState: PageEditState?,
        savedState: PageEditState?
    ) async {
        guard let page, let editState, let savedState else {
            clearPreview()
            return
        }

        guard editState != savedState else {
            clearPreview(sourceFileName: page.originalImageFileName)
            return
        }

        let requestKey =
            "\(page.originalImageFileName)|\(editState.filterPreset.rawValue)|\(editState.rotationDegrees)"
        guard requestKey != activeRequestKey || previewImage == nil else { return }

        let previousSourceFileName = activeSourceFileName
        activeRequestKey = requestKey
        activeSourceFileName = page.originalImageFileName
        let previewMaxDimension = reusableMaxDimension

        if let cachedImage = imageCache.object(forKey: requestKey as NSString) {
            previewImage = cachedImage
            previewRequestKey = requestKey
            isGenerating = false
            supportsPersistedReuse = previewMaxDimension >= reusableMaxDimension
            return
        }

        previewImage = nil
        previewRequestKey = nil
        isGenerating = true
        supportsPersistedReuse = false

        do {
            let sourceFileName = page.originalImageFileName
            let filterPreset = editState.filterPreset
            let rotationDegrees = editState.rotationDegrees
            let generatedImage = try await Task.detached(priority: .userInitiated) {
                guard let sourceImage = ImageStorageService.loadImage(
                    fileName: sourceFileName,
                    maxDimension: previewMaxDimension
                ) else {
                    throw PreviewGenerationError.sourceImageMissing
                }

                if filterPreset == .original, rotationDegrees == 0 {
                    return sourceImage
                }

                guard let renderedImage = ImageFilterService.applyFilter(
                    filterPreset,
                    to: sourceImage,
                    rotation: rotationDegrees,
                    intent: .preview,
                    previewMaxDimension: previewMaxDimension
                ) else {
                    throw PreviewGenerationError.renderedImageMissing
                }
                return renderedImage
            }.value

            guard activeRequestKey == requestKey else {
                return
            }

            if let previousSourceFileName, previousSourceFileName != sourceFileName {
                WorkingPreviewStorageService.deleteWorkingPreviews(sourceFileName: previousSourceFileName)
            }
            imageCache.setObject(generatedImage, forKey: requestKey as NSString)
            previewImage = generatedImage
            previewRequestKey = requestKey
            isGenerating = false
            supportsPersistedReuse = previewMaxDimension >= reusableMaxDimension
        } catch {
            guard activeRequestKey == requestKey else { return }
            previewImage = nil
            previewRequestKey = nil
            isGenerating = false
            supportsPersistedReuse = false
        }
    }

    func clearPreview(sourceFileName: String? = nil) {
        let targetSourceFileName = sourceFileName ?? activeSourceFileName
        if let targetSourceFileName {
            WorkingPreviewStorageService.deleteWorkingPreviews(sourceFileName: targetSourceFileName)
        }

        previewImage = nil
        previewRequestKey = nil
        activeRequestKey = nil
        activeSourceFileName = nil
        isGenerating = false
        supportsPersistedReuse = false
    }
}
