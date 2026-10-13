import UIKit

/// Bounds retained image bytes explicitly; NSCache's cost limits are advisory.
final class ImageMemoryCache: @unchecked Sendable {
    private struct Entry {
        let image: UIImage
        let cost: Int
    }

    private let lock = NSLock()
    private let byteLimit: Int
    private let countLimit: Int
    private var entries: [String: Entry] = [:]
    private var accessOrder: [String] = []
    private var totalCost = 0
    private var memoryWarningObserver: NSObjectProtocol?

    init(byteLimit: Int, countLimit: Int) {
        self.byteLimit = max(0, byteLimit)
        self.countLimit = max(0, countLimit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAllImages()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func image(forKey key: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        return entry.image
    }

    func insert(_ image: UIImage, forKey key: String) {
        let cost: Int
        if let cgImage = image.cgImage {
            cost = cgImage.bytesPerRow * cgImage.height
        } else {
            cost = Int(ceil(image.size.width * image.scale))
                * Int(ceil(image.size.height * image.scale)) * 4
        }

        lock.lock()
        defer { lock.unlock() }
        removeLocked(key)
        guard cost <= byteLimit, countLimit > 0 else { return }
        while totalCost + cost > byteLimit || entries.count >= countLimit {
            guard let oldestKey = accessOrder.first else { break }
            removeLocked(oldestKey)
        }
        entries[key] = Entry(image: image, cost: cost)
        accessOrder.append(key)
        totalCost += cost
    }

    func removeImage(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(key)
    }

    func removeAllImages() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        accessOrder.removeAll()
        totalCost = 0
    }

    private func removeLocked(_ key: String) {
        if let entry = entries.removeValue(forKey: key) {
            totalCost -= entry.cost
        }
        accessOrder.removeAll { $0 == key }
    }
}
