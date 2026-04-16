import PhotosUI
import SwiftUI

struct ImprovementReportPreviewState: Identifiable {
    let filter: FilterPreset
    var image: UIImage?
    var isLoading = true
    var errorMessage: String?

    var id: String { filter.rawValue }
}

@MainActor @Observable
final class ImprovementReportViewModel {
    let pageReportID: String
    let sourceImageFileName: String
    let rotationDegrees: Int
    let currentFilterRawValue: String

    var appVersion = ""
    var buildNumber = ""
    var timestampJst = ""
    var comment = ""
    var previews: [ImprovementReportPreviewState] = FilterPreset.allCases.map {
        ImprovementReportPreviewState(filter: $0)
    }
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
        currentFilterRawValue: String
    ) {
        self.pageReportID = pageReportID
        self.sourceImageFileName = sourceImageFileName
        self.rotationDegrees = rotationDegrees
        self.currentFilterRawValue = currentFilterRawValue
    }

    func initialize() {
        guard !initialized else { return }
        initialized = true

        let version = ImprovementReportService.appVersionLabel()
        appVersion = version.version
        buildNumber = version.build
        timestampJst = ImprovementReportService.buildTimestampJst()

        generatePreviews()
    }

    var canSend: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && previews.allSatisfy { !$0.isLoading && $0.image != nil && $0.errorMessage == nil }
            && !isSending
    }

    var allPreviewsReady: Bool {
        previews.allSatisfy { !$0.isLoading && $0.image != nil && $0.errorMessage == nil }
    }

    func onBackRequested() -> Bool {
        let shouldConfirmDiscard = allPreviewsReady && !isSending
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
                let previewImages: [FilterPreset: UIImage] = Dictionary(
                    uniqueKeysWithValues: previews.compactMap { preview in
                        guard let image = preview.image else { return nil }
                        return (preview.filter, image)
                    }
                )
                archiveURL = try ImprovementReportService.createArchive(
                    sourceImageFileName: sourceImageFileName,
                    previewImages: previewImages,
                    attachments: attachments
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

    func addAttachment(from item: PhotosPickerItem) {
        let nextIndex = attachments.count + 1
        Task {
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
                    ?? "追加画像を読み込めませんでした。"
            }
        }
    }

    private func generatePreviews() {
        for filter in FilterPreset.allCases {
            Task {
                do {
                    let image = try await ImprovementReportService.renderPreview(
                        sourceImageFileName: sourceImageFileName,
                        filter: filter,
                        rotationDegrees: rotationDegrees
                    )
                    updatePreview(filter: filter) {
                        $0.image = image
                        $0.isLoading = false
                        $0.errorMessage = nil
                    }
                } catch {
                    updatePreview(filter: filter) {
                        $0.image = nil
                        $0.isLoading = false
                        $0.errorMessage = (error as? LocalizedError)?.errorDescription
                            ?? "プレビューの生成に失敗しました。"
                    }
                }
            }
        }
    }

    private func updatePreview(filter: FilterPreset, mutate: (inout ImprovementReportPreviewState) -> Void) {
        guard let index = previews.firstIndex(where: { $0.filter == filter }) else { return }
        mutate(&previews[index])
    }
}
