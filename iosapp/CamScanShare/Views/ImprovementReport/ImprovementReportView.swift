import SwiftUI
import PhotosUI

struct ImprovementReportView: View {
    let pageReportId: String
    let sourceImageFileName: String
    let rotationDegrees: Int
    let currentFilterRawValue: String
    let debugCaptureId: String?
    @Binding var path: NavigationPath

    @State private var viewModel: ImprovementReportViewModel
    @State private var selectedPhotoItems: [PhotosPickerItem] = []

    init(
        pageReportId: String,
        sourceImageFileName: String,
        rotationDegrees: Int,
        currentFilterRawValue: String,
        debugCaptureId: String?,
        path: Binding<NavigationPath>
    ) {
        self.pageReportId = pageReportId
        self.sourceImageFileName = sourceImageFileName
        self.rotationDegrees = rotationDegrees
        self.currentFilterRawValue = currentFilterRawValue
        self.debugCaptureId = debugCaptureId
        _path = path
        _viewModel = State(
            initialValue: ImprovementReportViewModel(
                pageReportID: pageReportId,
                sourceImageFileName: sourceImageFileName,
                rotationDegrees: rotationDegrees,
                currentFilterRawValue: currentFilterRawValue,
                debugCaptureId: debugCaptureId
            )
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topAppBar

                ScrollView {
                    LazyVStack(spacing: 16) {
                        reportInfoCard
                        attachmentCard
                        debugPayloadCard
                    }
                    .padding(16)
                    .padding(.bottom, 120)
                }
                .background(Color(.systemGray6))
            }

            if viewModel.showSuccessFeedback {
                successFeedbackOverlay
            }
        }
        .safeAreaInset(edge: .bottom) {
            footerBar
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.initialize()
        }
        .onChange(of: viewModel.shouldClose) { _, shouldClose in
            if shouldClose, path.count > 0 {
                path.removeLast()
            }
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            viewModel.addAttachments(from: newItems)
            selectedPhotoItems = []
        }
        .alert("改善レポートを送信せずにもどりますか？", isPresented: $viewModel.showDiscardDialog) {
            Button("キャンセル", role: .cancel) {
                viewModel.onDiscardDismissed()
            }
            Button("OK", role: .destructive) {
                viewModel.onDiscardConfirmed()
            }
        } message: {
            Text("入力したコメントと追加写真は破棄されます。")
        }
        .alert(
            "送信に失敗しました",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.clearError() } }
            )
        ) {
            Button("キャンセル", role: .cancel) {
                viewModel.clearError()
            }
            Button("再試行") {
                viewModel.retryAfterError()
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .fullScreenCover(isPresented: $viewModel.showScannerSheet) {
            QRCodeScannerSheet(
                onScanned: { viewModel.handleScannedValue($0) },
                onFailure: { viewModel.onScannerFailure($0) },
                onCancel: { viewModel.onScannerCancelled() }
            )
        }
    }

    private var topAppBar: some View {
        HStack(spacing: 4) {
            Button {
                if viewModel.onBackRequested(), path.count > 0 {
                    path.removeLast()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text("改善レポート送信")
                    .font(.system(size: 18, weight: .medium))
                Text("デバッグ出力と比較写真を送信")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var reportInfoCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("レポート情報")
                    .font(.system(size: 15, weight: .bold))

                readOnlyField(
                    label: "アプリのバージョン / ビルド番号",
                    value: "\(viewModel.appVersion) (\(viewModel.buildNumber))"
                )
                readOnlyField(label: "日時 (JST)", value: viewModel.timestampJst)

                VStack(alignment: .leading, spacing: 6) {
                    Text("コメント (必須)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    TextEditor(text: Binding(
                        get: { viewModel.comment },
                        set: { viewModel.comment = String($0.prefix(300)) }
                    ))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 108)
                    .padding(10)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color(.separator), lineWidth: 1)
                    )

                    HStack {
                        Spacer()
                        Text("\(viewModel.comment.count) / 300")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var attachmentCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("比較用の追加写真")
                            .font(.system(size: 15, weight: .bold))
                        Text("CamScanner など別アプリの出力画像やスクリーンショットを任意で添付できます。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    PhotosPicker(
                        selection: $selectedPhotoItems,
                        maxSelectionCount: nil,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                            Text("写真を追加")
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isSending)
                }

                if viewModel.attachments.isEmpty {
                    Text("追加写真はまだありません。比較結果をコメントで説明したい場合だけ添付します。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        )
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(viewModel.attachments.enumerated()), id: \.element.id) { index, attachment in
                            attachmentRow(attachment: attachment, index: index)
                        }
                    }
                }
            }
        }
    }

    private func attachmentRow(
        attachment: ImprovementReportAttachment,
        index: Int
    ) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: attachment.previewImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(2)
                Text("追加写真 \(index + 1)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button(role: .destructive) {
                viewModel.removeAttachment(attachment)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 34, height: 34)
            }
            .disabled(viewModel.isSending)
        }
        .padding(12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var debugPayloadCard: some View {
        cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                Text("送信されるデータ")
                    .font(.system(size: 15, weight: .bold))
                Text("各フィルタの再生成は行わず、端末内に保存済みのこの撮影のデバッグ成果物を zip にまとめて送信します。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                payloadRow(label: "source.jpg", value: "対象ページの元画像が見つかった場合に同梱します。")
                payloadRow(label: "attachments/", value: "任意で追加した比較用写真を同梱します。")
                payloadRow(label: "debug/", value: "metadata.json、中間 PNG、timings.jsonl をこの撮影に紐づくセッションごとに同梱します。")
            }
        }
    }

    private var footerBar: some View {
        VStack(spacing: 8) {
            Text(footerText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                Button("キャンセル") {
                    if viewModel.onBackRequested(), path.count > 0 {
                        path.removeLast()
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 16))
                .disabled(viewModel.isSending)

                Button {
                    viewModel.openScanner()
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isSending {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(viewModel.isSending ? "改善レポートを送信中..." : "改善レポートサーバーへ")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canSend)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(.regularMaterial)
    }

    private var successFeedbackOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Text("✔")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(Color.green)
                Text("レポート送信完了")
                    .font(.system(size: 20, weight: .bold))
            }
            .frame(width: 240)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private func readOnlyField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        }
    }

    private func payloadRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func cardContainer<Content: View>(
        background: Color = Color(.systemBackground),
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(16)
        .background(background, in: RoundedRectangle(cornerRadius: 20))
    }

    private var footerText: String {
        if viewModel.isSending {
            return "改善レポートを送信中..."
        }
        if viewModel.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "コメントを入力すると送信ボタンが有効になります。"
        }
        if !viewModel.attachments.isEmpty {
            return "追加写真 \(viewModel.attachments.count) 枚も含めて、この撮影の画像処理デバッグ出力とログを送信します。"
        }
        return "この撮影の画像処理デバッグ出力とログを送信します。未送信のまま戻ると、入力したコメントは破棄されます。"
    }
}
