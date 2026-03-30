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
        let url = imagesDirectory.appendingPathComponent(fileName)
        if let data = image.jpegData(compressionQuality: 0.9) {
            try? data.write(to: url)
        }
        thumbnailCache.removeAllObjects()
        return fileName
    }

    static func loadImage(fileName: String) -> UIImage? {
        let url = imagesDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func deleteImage(fileName: String) {
        let url = imagesDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
        thumbnailCache.removeAllObjects()
        aspectRatioCache.removeAllObjects()
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

        let url = imagesDirectory.appendingPathComponent(fileName) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            return nil
        }

        let ratio = pixelWidth / pixelHeight
        aspectRatioCache.setObject(NSNumber(value: Double(ratio)), forKey: cacheKey)
        return ratio
    }
}
