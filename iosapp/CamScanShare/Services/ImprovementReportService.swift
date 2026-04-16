import Foundation
import UIKit
import UniformTypeIdentifiers

struct ImprovementReportServerConfig: Sendable {
    let reportURL: URL
    let token: String
}

struct ImprovementReportMetadata: Sendable {
    let appVersion: String
    let buildNumber: String
    let timestampJst: String
    let pageID: String
    let currentFilter: String
    let comment: String
}

struct ImprovementReportAttachment: Identifiable {
    let id = UUID()
    let displayName: String
    let data: Data
    let previewImage: UIImage
    let fileExtension: String
}

enum ImprovementReportService {
    enum ServiceError: LocalizedError {
        case sourceImageMissing
        case previewGenerationFailed
        case invalidQRCode
        case missingUploadConfig
        case invalidPhoto
        case uploadFailed(message: String)

        var errorDescription: String? {
            switch self {
            case .sourceImageMissing:
                "元画像を読み込めませんでした。"
            case .previewGenerationFailed:
                "プレビューの生成に失敗しました。"
            case .invalidQRCode:
                "QRコードの形式が正しくありません。"
            case .missingUploadConfig:
                "送信先 URL またはアクセストークンが不足しています。"
            case .invalidPhoto:
                "追加画像を読み込めませんでした。"
            case .uploadFailed(let message):
                message
            }
        }
    }

    static func appVersionLabel() -> (version: String, build: String) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
            ?? "unknown"
        return (version, build)
    }

    static func buildTimestampJst(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'JST'"
        return formatter.string(from: now)
    }

    static func renderPreview(
        sourceImageFileName: String,
        filter: FilterPreset,
        rotationDegrees: Int
    ) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            guard let sourceImage = ImageStorageService.loadImage(
                fileName: sourceImageFileName,
                maxDimension: 1600
            ) else {
                throw ServiceError.sourceImageMissing
            }

            if filter == .original, rotationDegrees == 0 {
                return sourceImage
            }

            guard let rendered = ImageFilterService.applyFilter(
                filter,
                to: sourceImage,
                rotation: rotationDegrees,
                intent: .preview,
                previewMaxDimension: 1600
            ) else {
                throw ServiceError.previewGenerationFailed
            }
            return rendered
        }.value
    }

    static func makePhotoAttachment(
        data: Data,
        contentType: UTType?,
        fallbackIndex: Int
    ) throws -> ImprovementReportAttachment {
        guard !data.isEmpty else { throw ServiceError.invalidPhoto }
        guard let image = UIImage(data: data) else {
            throw ServiceError.invalidPhoto
        }

        let fileExtension = contentType?.preferredFilenameExtension?
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let normalizedExtension = (fileExtension?.isEmpty == false ? fileExtension! : "jpg")
        let displayName = "photo-\(fallbackIndex).\(normalizedExtension)"

        return ImprovementReportAttachment(
            displayName: displayName,
            data: data,
            previewImage: image,
            fileExtension: normalizedExtension
        )
    }

    static func parseScannerPayload(_ rawValue: String) throws -> ImprovementReportServerConfig {
        guard let components = URLComponents(string: rawValue),
            components.scheme == "camscanshare",
            components.host == "bug-report-config"
        else {
            throw ServiceError.invalidQRCode
        }

        let reportURLString = components.queryItems?.first(where: { $0.name == "u" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = components.queryItems?.first(where: { $0.name == "t" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !reportURLString.isEmpty, !token.isEmpty else {
            throw ServiceError.missingUploadConfig
        }

        guard let reportURL = URL(string: reportURLString),
            let scheme = reportURL.scheme,
            scheme == "https" || scheme == "http"
        else {
            throw ServiceError.invalidQRCode
        }

        return ImprovementReportServerConfig(reportURL: reportURL, token: token)
    }

    static func createArchive(
        sourceImageFileName: String,
        previewImages: [FilterPreset: UIImage],
        attachments: [ImprovementReportAttachment]
    ) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("improvement-report-\(UUID().uuidString)")
            .appendingPathExtension("zip")

        var entries: [ZipEntryPayload] = []

        if let originalImage = previewImages[.original],
            let data = originalImage.jpegData(compressionQuality: 0.9)
        {
            entries.append(ZipEntryPayload(name: "original.jpg", data: data))
        }

        for filter in FilterPreset.allCases where filter != .original {
            guard let image = previewImages[filter],
                let data = image.jpegData(compressionQuality: 0.9)
            else {
                continue
            }
            entries.append(ZipEntryPayload(name: "filter-\(filter.rawValue).jpg", data: data))
        }

        let sourceURL = ImageStorageService.sourceImageURL(fileName: sourceImageFileName)
        if let sourceData = try? Data(contentsOf: sourceURL) {
            entries.append(ZipEntryPayload(name: "source.jpg", data: sourceData))
        }

        for (index, attachment) in attachments.enumerated() {
            entries.append(
                ZipEntryPayload(
                    name: "extra-\(index + 1).\(attachment.fileExtension)",
                    data: attachment.data
                )
            )
        }

        try SimpleZipWriter.write(entries: entries, to: outputURL)
        return outputURL
    }

    static func uploadReport(
        config: ImprovementReportServerConfig,
        metadata: ImprovementReportMetadata,
        archiveURL: URL
    ) async throws {
        let boundary = "----CamScanShare\(UUID().uuidString)"
        let archiveData = try Data(contentsOf: archiveURL)
        var body = Data()

        appendTextField(named: "comment", value: metadata.comment, boundary: boundary, to: &body)
        appendTextField(named: "appVersion", value: metadata.appVersion, boundary: boundary, to: &body)
        appendTextField(named: "buildNumber", value: metadata.buildNumber, boundary: boundary, to: &body)
        appendTextField(named: "timestampJst", value: metadata.timestampJst, boundary: boundary, to: &body)
        appendTextField(named: "pageId", value: metadata.pageID, boundary: boundary, to: &body)
        appendTextField(named: "currentFilter", value: metadata.currentFilter, boundary: boundary, to: &body)

        body.append("--\(boundary)\r\n".utf8Data)
        body.append(
            "Content-Disposition: form-data; name=\"archive\"; filename=\"\(archiveURL.lastPathComponent)\"\r\n".utf8Data
        )
        body.append("Content-Type: application/zip\r\n\r\n".utf8Data)
        body.append(archiveData)
        body.append("\r\n".utf8Data)
        body.append("--\(boundary)--\r\n".utf8Data)

        var request = URLRequest(url: config.reportURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ServiceError.uploadFailed(message: "改善レポート送信に失敗しました。")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.uploadFailed(
                message: "改善レポート送信に失敗しました (HTTP \(httpResponse.statusCode)) \(responseText)"
            )
        }
    }

    private static func appendTextField(
        named name: String,
        value: String,
        boundary: String,
        to data: inout Data
    ) {
        data.append("--\(boundary)\r\n".utf8Data)
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8Data)
        data.append(value.utf8Data)
        data.append("\r\n".utf8Data)
    }
}

private struct ZipEntryPayload {
    let name: String
    let data: Data
    let modificationDate: Date = Date()
}

private enum SimpleZipWriter {
    static func write(entries: [ZipEntryPayload], to destinationURL: URL) throws {
        var archiveData = Data()
        var centralDirectory = Data()
        var currentOffset: UInt32 = 0

        for entry in entries {
            let nameData = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let dosDateTime = entry.modificationDate.dosDateTime
            let uncompressedSize = UInt32(entry.data.count)

            var localHeader = Data()
            localHeader.append(littleEndian: UInt32(0x04034B50))
            localHeader.append(littleEndian: UInt16(20))
            localHeader.append(littleEndian: UInt16(0))
            localHeader.append(littleEndian: UInt16(0))
            localHeader.append(littleEndian: dosDateTime.time)
            localHeader.append(littleEndian: dosDateTime.date)
            localHeader.append(littleEndian: crc)
            localHeader.append(littleEndian: uncompressedSize)
            localHeader.append(littleEndian: uncompressedSize)
            localHeader.append(littleEndian: UInt16(nameData.count))
            localHeader.append(littleEndian: UInt16(0))
            localHeader.append(nameData)

            archiveData.append(localHeader)
            archiveData.append(entry.data)

            var centralHeader = Data()
            centralHeader.append(littleEndian: UInt32(0x02014B50))
            centralHeader.append(littleEndian: UInt16(20))
            centralHeader.append(littleEndian: UInt16(20))
            centralHeader.append(littleEndian: UInt16(0))
            centralHeader.append(littleEndian: UInt16(0))
            centralHeader.append(littleEndian: dosDateTime.time)
            centralHeader.append(littleEndian: dosDateTime.date)
            centralHeader.append(littleEndian: crc)
            centralHeader.append(littleEndian: uncompressedSize)
            centralHeader.append(littleEndian: uncompressedSize)
            centralHeader.append(littleEndian: UInt16(nameData.count))
            centralHeader.append(littleEndian: UInt16(0))
            centralHeader.append(littleEndian: UInt16(0))
            centralHeader.append(littleEndian: UInt16(0))
            centralHeader.append(littleEndian: UInt16(0))
            centralHeader.append(littleEndian: UInt32(0))
            centralHeader.append(littleEndian: currentOffset)
            centralHeader.append(nameData)
            centralDirectory.append(centralHeader)

            currentOffset += UInt32(localHeader.count + entry.data.count)
        }

        let centralDirectoryOffset = UInt32(archiveData.count)
        archiveData.append(centralDirectory)

        var endRecord = Data()
        endRecord.append(littleEndian: UInt32(0x06054B50))
        endRecord.append(littleEndian: UInt16(0))
        endRecord.append(littleEndian: UInt16(0))
        endRecord.append(littleEndian: UInt16(entries.count))
        endRecord.append(littleEndian: UInt16(entries.count))
        endRecord.append(littleEndian: UInt32(centralDirectory.count))
        endRecord.append(littleEndian: centralDirectoryOffset)
        endRecord.append(littleEndian: UInt16(0))
        archiveData.append(endRecord)

        try archiveData.write(to: destinationURL, options: .atomic)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = 0xEDB88320 ^ (crc >> 1)
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Date {
    var dosDateTime: (date: UInt16, time: UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone.current, from: self)
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = max(components.month ?? 1, 1)
        let day = max(components.day ?? 1, 1)
        let hour = max(components.hour ?? 0, 0)
        let minute = max(components.minute ?? 0, 0)
        let second = max((components.second ?? 0) / 2, 0)

        let dosDate = UInt16((year << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        return (dosDate, dosTime)
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func append(littleEndian value: UInt32) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

private extension String {
    var utf8Data: Data { Data(utf8) }
}
