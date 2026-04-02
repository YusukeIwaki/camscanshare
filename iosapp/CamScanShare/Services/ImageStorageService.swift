import UIKit
import ImageIO

enum ImageStorageService {
    private static var imagesDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScannedImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated(unsafe) static let thumbnailCache = NSCache<NSString, UIImage>()
    private nonisolated(unsafe) static let aspectRatioCache = NSCache<NSString, NSNumber>()

    static func saveImage(_ image: UIImage) -> String {
        let fileName = UUID().uuidString + ".jpg"
        let url = sourceImageURL(fileName: fileName)
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: url)
        }
        thumbnailCache.removeAllObjects()
        return fileName
    }

    static func loadImage(fileName: String) -> UIImage? {
        loadImage(fileName: fileName, maxDimension: nil)
    }

    static func loadImage(fileName: String, maxDimension: CGFloat?) -> UIImage? {
        let url = sourceImageURL(fileName: fileName)
        guard let maxDimension, maxDimension > 0 else {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }

        let cacheKey = "sampled_\(fileName)_\(Int(maxDimension.rounded(.up)))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDimension.rounded(.up))),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        thumbnailCache.setObject(image, forKey: cacheKey)
        return image
    }

    static func deleteImage(fileName: String) {
        let url = sourceImageURL(fileName: fileName)
        try? FileManager.default.removeItem(at: url)
        thumbnailCache.removeAllObjects()
        aspectRatioCache.removeAllObjects()
    }

    static func sourceImageURL(fileName: String) -> URL {
        imagesDirectory.appendingPathComponent(fileName)
    }

    static func imageExists(fileName: String?) -> Bool {
        guard let fileName else { return false }
        return FileManager.default.fileExists(atPath: sourceImageURL(fileName: fileName).path)
    }

    static func thumbnail(fileName: String, size: CGSize) -> UIImage? {
        let cacheKey = "\(fileName)_\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: cacheKey) {
            return cached
        }
        guard let image = loadImage(fileName: fileName) else { return nil }
        let thumb = image.preparingThumbnail(of: size) ?? image
        thumbnailCache.setObject(thumb, forKey: cacheKey)
        return thumb
    }

    static func imageAspectRatio(fileName: String) -> CGFloat? {
        let cacheKey = fileName as NSString
        if let cached = aspectRatioCache.object(forKey: cacheKey) {
            return CGFloat(cached.doubleValue)
        }

        let url = sourceImageURL(fileName: fileName)
        let ratio = imageAspectRatio(at: url)
        if let ratio {
            aspectRatioCache.setObject(NSNumber(value: Double(ratio)), forKey: cacheKey)
        }
        return ratio
    }

    static func imageAspectRatio(at url: URL) -> CGFloat? {
        let url = url as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            return nil
        }

        return pixelWidth / pixelHeight
    }
}
