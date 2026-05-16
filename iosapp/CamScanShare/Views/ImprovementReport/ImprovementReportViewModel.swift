import PhotosUI
import SwiftUI

@MainActor @Observable
final class ImprovementReportViewModel {
    let pageReportID: String
    let sourceImageFileName: String
    let currentFilterRawValue: String
    let debugCaptureId: String?

    var appVersion = ""
    var buildNumber = ""
    var timestampJst = ""
    var comment = ""
    var attachments: [ImprovementReportAttachment] = []
    var isSending = false
    var showDiscardDialog = false
    var showScannerSheet = false
    var errorMessage: String?
    var shouldClose = false
    var showSuccessFeedback = false

    private var initialized = false

    init(
        pageReportID: String,
        sourceImageFileName: String,
        rotationDegrees: Int,
        currentFilterRawValue: String,
        debugCaptureId: String?
    ) {
        self.pageReportID = pageReportID
        self.sourceImageFileName = sourceImageFileName
        self.currentFilterRawValue = currentFilterRawValue
        self.debugCaptureId = debugCaptureId
    }

    func initialize() {
        guard !initialized else { return }
        initialized = true

        let version = ImprovementReportService.appVersionLabel()
        appVersion = version.version
        buildNumber = version.build
        timestampJst = ImprovementReportService.buildTimestampJst()
    }

    var canSend: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    func onBackRequested() -> Bool {
        let shouldConfirmDiscard = (
            !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        ) && !isSending
        if shouldConfirmDiscard {
            showDiscardDialog = true
            return false
        }
        return true
    }

    func onDiscardConfirmed() {
        showDiscardDialog = false
        shouldClose = true
    }

    func onDiscardDismissed() {
        showDiscardDialog = false
    }

    func clearError() {
        errorMessage = nil
    }

    func retryAfterError() {
        errorMessage = nil
        showScannerSheet = true
    }

    func openScanner() {
        guard canSend else { return }
        showScannerSheet = true
    }

    func addAttachments(from items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                let nextIndex = attachments.count + 1
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw ImprovementReportService.ServiceError.invalidPhoto
                    }
                    let attachment = try ImprovementReportService.makePhotoAttachment(
                        data: data,
                        contentType: item.supportedContentTypes.first,
                        fallbackIndex: nextIndex
                    )
                    attachments.append(attachment)
                } catch {
                    errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "追加写真を読み込めませんでした。"
                }
            }
        }
    }

    func removeAttachment(_ attachment: ImprovementReportAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func onScannerCancelled() {
        showScannerSheet = false
    }

    func onScannerFailure(_ message: String) {
        showScannerSheet = false
        isSending = false
        errorMessage = message
    }

    func handleScannedValue(_ rawValue: String) {
        guard canSend else { return }
        showScannerSheet = false

        Task {
            isSending = true
            errorMessage = nil

            var archiveURL: URL?
            do {
                let config = try ImprovementReportService.parseScannerPayload(rawValue)
                archiveURL = try ImprovementReportService.createArchive(
                    sourceImageFileName: sourceImageFileName,
                    attachments: attachments,
                    debugCaptureId: debugCaptureId
                )
                try await ImprovementReportService.uploadReport(
                    config: config,
                    metadata: ImprovementReportMetadata(
                        appVersion: appVersion,
                        buildNumber: buildNumber,
                        timestampJst: timestampJst,
                        pageID: pageReportID,
                        currentFilter: currentFilterRawValue,
                        comment: comment.trimmingCharacters(in: .whitespacesAndNewlines)
                    ),
                    archiveURL: archiveURL!
                )

                isSending = false
                showSuccessFeedback = true
                try? await Task.sleep(for: .milliseconds(900))
                showSuccessFeedback = false
                shouldClose = true
            } catch {
                isSending = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "改善レポート送信に失敗しました。"
            }

            if let archiveURL {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }
    }
}
