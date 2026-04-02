import Foundation
import SwiftData
import UIKit

enum PreviewImageKind: String, Sendable {
    case small
    case large
    case working

    var pathComponent: String {
        switch self {
        case .small:
            "PreviewImages/small"
        case .large:
            "PreviewImages/large"
        case .working:
            "PreviewImages/working"
        }
    }
}

struct PagePreviewFiles: Sendable, Equatable {
    let smallFileName: String
    let largeFileName: String
}

enum PreviewGenerationError: Error {
    case sourceImageMissing
    case renderedImageMissing
    case previewSaveFailed
}

enum PreviewStorageService {
    private nonisolated(unsafe) static let imageCache = NSCache<NSString, UIImage>()
    private nonisolated(unsafe) static let aspectRatioCache = NSCache<NSString, NSNumber>()

    static func fileURL(fileName: String, kind: PreviewImageKind) -> URL {
        directoryURL(for: kind).appendingPathComponent(fileName)
    }

    static func savePreview(
        _ image: UIImage,
        kind: PreviewImageKind,
        baseName: String? = nil,
        compressionQuality: CGFloat = 0.82
    ) throws -> String {
        let fileName = generatedFileName(baseName: baseName)
        let url = fileURL(fileName: fileName, kind: kind)
        guard let data = image.jpegData(compressionQuality: compressionQuality) else {
            throw PreviewGenerationError.previewSaveFailed
        }
        try data.write(to: url, options: .atomic)
        invalidateCache(fileName: fileName, kind: kind)
        return fileName
    }

    static func loadPreview(fileName: String, kind: PreviewImageKind) -> UIImage? {
        let cacheKey = cacheKey(fileName: fileName, kind: kind)
        if let cached = imageCache.object(forKey: cacheKey as NSString) {
            return cached
        }

        let url = fileURL(fileName: fileName, kind: kind)
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return nil
        }
        imageCache.setObject(image, forKey: cacheKey as NSString)
        return image
    }

    static func deletePreview(fileName: String?, kind: PreviewImageKind) {
        guard let fileName else { return }
        let url = fileURL(fileName: fileName, kind: kind)
        try? FileManager.default.removeItem(at: url)
        invalidateCache(fileName: fileName, kind: kind)
    }

    static func deleteAllPreviews(kind: PreviewImageKind) {
        let directory = directoryURL(for: kind)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
        imageCache.removeAllObjects()
        aspectRatioCache.removeAllObjects()
    }

    static func previewExists(fileName: String?, kind: PreviewImageKind) -> Bool {
        guard let fileName else { return false }
        return FileManager.default.fileExists(atPath: fileURL(fileName: fileName, kind: kind).path)
    }

    static func imageAspectRatio(fileName: String?, kind: PreviewImageKind) -> CGFloat? {
        guard let fileName else { return nil }
        let cacheKey = cacheKey(fileName: fileName, kind: kind)
        if let cached = aspectRatioCache.object(forKey: cacheKey as NSString) {
            return CGFloat(cached.doubleValue)
        }

        let url = fileURL(fileName: fileName, kind: kind)
        let ratio = ImageStorageService.imageAspectRatio(at: url)
        if let ratio {
            aspectRatioCache.setObject(NSNumber(value: Double(ratio)), forKey: cacheKey as NSString)
        }
        return ratio
    }

    static func listPreviewFileNames(kind: PreviewImageKind) -> [String] {
        let directory = directoryURL(for: kind)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.map(\.lastPathComponent)
    }

    static func savePersistedPreviews(
        from renderedImage: UIImage,
        sourceFileName: String,
        smallMaxDimension: CGFloat = 160,
        largeMaxDimension: CGFloat = 1600
    ) throws -> PagePreviewFiles {
        let largePreview = renderedImage.scaledToFit(maxDimension: largeMaxDimension)
        let smallPreview = renderedImage.scaledToFit(maxDimension: smallMaxDimension)
        let baseName = URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent
        let smallFileName = try savePreview(
            smallPreview,
            kind: .small,
            baseName: baseName
        )
        let largeFileName = try savePreview(
            largePreview,
            kind: .large,
            baseName: baseName
        )
        return PagePreviewFiles(smallFileName: smallFileName, largeFileName: largeFileName)
    }

    private static func directoryURL(for kind: PreviewImageKind) -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(kind.pathComponent, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func generatedFileName(baseName: String?) -> String {
        let sanitizedBase = (baseName ?? UUID().uuidString)
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let prefix = sanitizedBase.isEmpty ? UUID().uuidString : sanitizedBase
        return "\(prefix)_\(UUID().uuidString).jpg"
    }

    private static func cacheKey(fileName: String, kind: PreviewImageKind) -> String {
        "\(kind.rawValue)_\(fileName)"
    }

    private static func invalidateCache(fileName: String, kind: PreviewImageKind) {
        let key = cacheKey(fileName: fileName, kind: kind) as NSString
        imageCache.removeObject(forKey: key)
        aspectRatioCache.removeObject(forKey: key)
    }
}

enum WorkingPreviewStorageService {
    static func saveWorkingPreview(_ image: UIImage, sourceFileName: String) throws -> String {
        try PreviewStorageService.savePreview(
            image,
            kind: .working,
            baseName: URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent
        )
    }

    static func loadWorkingPreview(fileName: String) -> UIImage? {
        PreviewStorageService.loadPreview(fileName: fileName, kind: .working)
    }

    static func deleteWorkingPreview(fileName: String?) {
        PreviewStorageService.deletePreview(fileName: fileName, kind: .working)
    }

    static func deleteWorkingPreviews(sourceFileName: String) {
        let prefix = URL(fileURLWithPath: sourceFileName).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        for fileName in PreviewStorageService.listPreviewFileNames(kind: .working)
        where fileName.hasPrefix(prefix) {
            deleteWorkingPreview(fileName: fileName)
        }
    }

    static func deleteAllWorkingPreviews() {
        PreviewStorageService.deleteAllPreviews(kind: .working)
    }
}

actor PreviewGenerationCoordinator {
    static let shared = PreviewGenerationCoordinator()

    private let smallMaxDimension: CGFloat = 160
    private let largeMaxDimension: CGFloat = 1600
    private var persistedTasks: [String: Task<PagePreviewFiles, Error>] = [:]

    func generatePersistedPreviews(
        sourceFileName: String,
        filter: FilterPreset,
        rotation: Int
    ) async throws -> PagePreviewFiles {
        let requestKey = "\(sourceFileName)|\(filter.rawValue)|\(rotation)|persisted"
        if let task = persistedTasks[requestKey] {
            return try await task.value
        }

        let task = Task<PagePreviewFiles, Error> {
            guard
                let sourceImage = ImageStorageService.loadImage(
                    fileName: sourceFileName,
                    maxDimension: largeMaxDimension
                )
            else {
                throw PreviewGenerationError.sourceImageMissing
            }
            let renderedImage: UIImage
            if filter == .original, rotation == 0 {
                renderedImage = sourceImage
            } else {
                guard let filtered = ImageFilterService.applyFilter(
                    filter,
                    to: sourceImage,
                    rotation: rotation,
                    intent: .preview,
                    previewMaxDimension: largeMaxDimension
                ) else {
                    throw PreviewGenerationError.renderedImageMissing
                }
                renderedImage = filtered
            }

            return try PreviewStorageService.savePersistedPreviews(
                from: renderedImage,
                sourceFileName: sourceFileName,
                smallMaxDimension: smallMaxDimension,
                largeMaxDimension: largeMaxDimension
            )
        }

        persistedTasks[requestKey] = task
        defer { persistedTasks[requestKey] = nil }
        return try await task.value
    }
}

func pageNeedsPreviewRegeneration(_ page: Page) -> Bool {
    !PreviewStorageService.previewExists(fileName: page.smallPreviewFileName, kind: .small)
        || !PreviewStorageService.previewExists(fileName: page.largePreviewFileName, kind: .large)
}

@MainActor
func reconcilePersistedPreviews(
    for page: Page,
    context: ModelContext,
    force: Bool = false,
    renderedPreviewImage: UIImage? = nil
) async {
    guard force || pageNeedsPreviewRegeneration(page) else { return }

    let oldSmallPreview = page.smallPreviewFileName
    let oldLargePreview = page.largePreviewFileName

    do {
        let files: PagePreviewFiles
        if let renderedPreviewImage {
            files = try PreviewStorageService.savePersistedPreviews(
                from: renderedPreviewImage,
                sourceFileName: page.originalImageFileName
            )
        } else {
            files = try await PreviewGenerationCoordinator.shared.generatePersistedPreviews(
                sourceFileName: page.originalImageFileName,
                filter: page.filterPreset,
                rotation: page.rotationDegrees
            )
        }
        page.smallPreviewFileName = files.smallFileName
        page.largePreviewFileName = files.largeFileName
        try? context.save()
        if oldSmallPreview != files.smallFileName {
            PreviewStorageService.deletePreview(fileName: oldSmallPreview, kind: .small)
        }
        if oldLargePreview != files.largeFileName {
            PreviewStorageService.deletePreview(fileName: oldLargePreview, kind: .large)
        }
    } catch {
        page.smallPreviewFileName = nil
        page.largePreviewFileName = nil
        try? context.save()
    }
}

func deletePageAssets(_ page: Page) {
    ImageStorageService.deleteImage(fileName: page.originalImageFileName)
    PreviewStorageService.deletePreview(fileName: page.smallPreviewFileName, kind: .small)
    PreviewStorageService.deletePreview(fileName: page.largePreviewFileName, kind: .large)
    WorkingPreviewStorageService.deleteWorkingPreviews(sourceFileName: page.originalImageFileName)
}
