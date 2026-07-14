import Foundation
import UIKit

final class ImageProcessingDebugSession: @unchecked Sendable {
    let directory: URL?
    let category: String
    let label: String

    private let lock = NSLock()
    private var imageIndex = 0

    init(directory: URL?, category: String, label: String) {
        self.directory = directory
        self.category = category
        self.label = label
    }

    var isEnabled: Bool {
        directory != nil
    }

    func nextImageFileName(label: String) -> String {
        lock.lock()
        imageIndex += 1
        let index = imageIndex
        lock.unlock()
        return String(format: "%02d_%@.png", index, Self.sanitize(label))
    }

    func appendTiming(_ line: String) {
        guard let directory else { return }
        let fileURL = directory.appendingPathComponent("timings.jsonl")
        lock.lock()
        defer { lock.unlock() }

        let lineData = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lineData)
                try? handle.close()
            }
        } else {
            try? lineData.write(to: fileURL)
        }
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "artifact" : sanitized
    }
}

final class ImageProcessingDebugSink: @unchecked Sendable {
    static let shared = ImageProcessingDebugSink(isWritingEnabled: false)

    private let rootDirectory: URL?
    private let isWritingEnabled: Bool
    private let debugCaptureId: String?
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private init(isWritingEnabled: Bool, debugCaptureId: String? = nil) {
        self.isWritingEnabled = isWritingEnabled
        self.debugCaptureId = debugCaptureId
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let rootURL = baseURL?.appendingPathComponent("ImageProcessingDebug", isDirectory: true)
        if let rootURL {
            try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
        rootDirectory = rootURL
    }

    static func writingEnabled(debugCaptureId: String? = nil) -> ImageProcessingDebugSink {
        ImageProcessingDebugSink(isWritingEnabled: true, debugCaptureId: debugCaptureId)
    }

    var debugRootDirectory: URL? {
        rootDirectory
    }

    func startSession(
        category: String,
        label: String,
        metadata: [String: String] = [:]
    ) -> ImageProcessingDebugSession {
        guard isWritingEnabled, let rootDirectory else {
            return ImageProcessingDebugSession(directory: nil, category: category, label: label)
        }

        let timestamp = timestampFormatter.string(from: Date())
        let directoryComponents = [timestamp]
            + [debugCaptureId.map(sanitize)].compactMap { $0 }
            + [sanitize(category), sanitize(label)]
        let directoryName = directoryComponents.joined(separator: "_")
        let directory = rootDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let session = ImageProcessingDebugSession(directory: directory, category: category, label: label)
            var values = metadata
            if let debugCaptureId {
                values["debugCaptureId"] = debugCaptureId
            }
            values["category"] = category
            values["label"] = label
            values["createdAt"] = timestamp
            values["path"] = directory.path
            writeText(session, fileName: "metadata.json", text: jsonObject(values))
            NSLog("ImageProcessingDebug session: %@", directory.path)
            return session
        } catch {
            NSLog("ImageProcessingDebug failed to create session: %@", String(describing: error))
            return ImageProcessingDebugSession(directory: nil, category: category, label: label)
        }
    }

    func writeImage(_ session: ImageProcessingDebugSession?, label: String, image: UIImage?) {
        guard let session, let directory = session.directory, let image, let data = image.pngData() else { return }
        let fileURL = directory.appendingPathComponent(session.nextImageFileName(label: label))
        do {
            try data.write(to: fileURL)
        } catch {
            NSLog("ImageProcessingDebug failed to write image %@: %@", label, String(describing: error))
        }
    }

    func writeText(_ session: ImageProcessingDebugSession?, fileName: String, text: String) {
        guard let directory = session?.directory else { return }
        let fileURL = directory.appendingPathComponent(fileName)
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            NSLog("ImageProcessingDebug failed to write text %@: %@", fileName, String(describing: error))
        }
    }

    func recordTiming(
        _ session: ImageProcessingDebugSession?,
        stage: String,
        durationMs: Double,
        metadata: [String: String] = [:]
    ) {
        guard session?.isEnabled == true else { return }
        var values = metadata
        values["stage"] = stage
        values["durationMs"] = String(format: "%.3f", durationMs)
        NSLog(
            "ImageProcessingDebug %@:%@ %@ %@ms",
            session?.category ?? "image",
            session?.label ?? "-",
            stage,
            values["durationMs"] ?? "0"
        )
        session?.appendTiming(jsonObject(values))
    }

    func recordTimingSince(
        _ session: ImageProcessingDebugSession?,
        stage: String,
        startedAt: TimeInterval,
        metadata: [String: String] = [:]
    ) {
        let durationMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        recordTiming(session, stage: stage, durationMs: durationMs, metadata: metadata)
    }

    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func recentSessionDirectories(limit: Int = 40) -> [URL] {
        guard let rootDirectory,
            let urls = try? FileManager.default.contentsOfDirectory(
                at: rootDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return urls
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            .prefix(limit)
            .map { $0 }
    }

    func sessionDirectories(debugCaptureId: String, limit: Int = 12) -> [URL] {
        let expected = "\"debugCaptureId\":\"\(escapeJson(debugCaptureId))\""
        return recentSessionDirectories(limit: 200)
            .filter { sessionURL in
                let metadataURL = sessionURL.appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metadataURL),
                    let text = String(data: data, encoding: .utf8)
                else {
                    return false
                }
                return text.contains(expected)
            }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }
            .prefix(limit)
            .map { $0 }
    }

    private func jsonObject(_ values: [String: String]) -> String {
        let entries = values.sorted { $0.key < $1.key }.map { key, value in
            "\"\(escapeJson(key))\":\"\(escapeJson(value))\""
        }
        return "{\(entries.joined(separator: ","))}"
    }

    private func escapeJson(_ value: String) -> String {
        var output = ""
        for character in value {
            switch character {
            case "\\":
                output += "\\\\"
            case "\"":
                output += "\\\""
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            default:
                output.append(character)
            }
        }
        return output
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "session" : sanitized
    }
}
