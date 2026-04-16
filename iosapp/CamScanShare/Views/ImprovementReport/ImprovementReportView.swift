import PhotosUI
import SwiftUI

struct ImprovementReportView: View {
    let pageReportId: String
    let sourceImageFileName: String
    let rotationDegrees: Int
    let currentFilterRawValue: String
    @Binding var path: NavigationPath

    @State private var viewModel: ImprovementReportViewModel
    @State private var selectedPhotoItem: PhotosPickerItem?

    init(
        pageReportId: String,
        sourceImageFileName: String,
        rotationDegrees: Int,
        currentFilterRawValue: String,
        path: Binding<NavigationPath>
    ) {
        self.pageReportId = pageReportId
        self.sourceImageFileName = sourceImageFileName
        self.rotationDegrees = rotationDegrees
        self.currentFilterRawValue = currentFilterRawValue
        _path = path
        _viewModel = State(
            initialValue: ImprovementReportViewModel(
                pageReportID: pageReportId,
                sourceImageFileName: sourceImageFileName,
                rotationDegrees: rotationDegrees,
                currentFilterRawValue: currentFilterRawValue
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

                        if !viewModel.allPreviewsReady {
                            progressCard
                        }

                        ForEach(viewModel.previews) { preview in
                            previewCard(preview)
                        }
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
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            viewModel.addAttachment(from: newItem)
            selectedPhotoItem = nil
        }
        .onChange(of: viewModel.shouldClose) { _, shouldClose in
            if shouldClose, path.count > 0 {
                path.removeLast()
            }
        }
        .alert("改善レポートを送信せずにもどりますか？", isPresented: $viewModel.showDiscardDialog) {
            Button("キャンセル", role: .cancel) {
                viewModel.onDiscardDismissed()
            }
            Button("OK", role: .destructive) {
                viewModel.onDiscardConfirmed()
            }
        } message: {
            Text("生成済みのプレビュー、追加した写真、入力したコメントは破棄されます。")
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
                Text("元画像と全フィルタ結果を送信")
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
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("追加で送る写真")
                            .font(.system(size: 15, weight: .bold))
                        Text("比較用の写真を任意で追加できます。画像のみ追加可能で、PDF などは選択できません。全フィルタの生成中でも操作できます。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        HStack(spacing: 6) {
                            Image(systemName: "photo.badge.plus")
                            Text("写真を追加")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(viewModel.isSending)
                }

                if viewModel.attachments.isEmpty {
                    Text("追加写真はまだありません。CamScanner との比較画像など、補足したい写真がある場合だけ追加します。")
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
                    VStack(spacing: 12) {
                        ForEach(Array(viewModel.attachments.enumerated()), id: \.element.id) { index, attachment in
                            HStack(spacing: 12) {
                                Image(uiImage: attachment.previewImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(attachment.displayName)
                                        .font(.system(size: 14, weight: .bold))
                                        .lineLimit(2)
                                    Text("写真 \(index + 1) / 追加画像として一緒に送信")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
        }
    }

    private var progressCard: some View {
        cardContainer(background: Color.accentColor.opacity(0.12)) {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 4) {
                    Text("変換プレビューを生成中...")
                        .font(.system(size: 14, weight: .bold))
                    Text(
                        "\(viewModel.previews.filter { !$0.isLoading && $0.image != nil }.count) / \(viewModel.previews.count) 件の画像を準備しました。すべて完了すると送信ボタンが活性化します。"
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private func previewCard(_ preview: ImprovementReportPreviewState) -> some View {
        let aspectRatio: CGFloat = {
            if let image = preview.image, image.size.height > 0 {
                return image.size.width / image.size.height
            }
            return ImageStorageService.imageAspectRatio(fileName: sourceImageFileName) ?? 210.0 / 297.0
        }()

        return cardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(preview.filter.displayName)
                        .font(.system(size: 15, weight: .bold))
                    Spacer()
                    Text(previewStatusText(preview))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(previewStatusColor(preview))
                }

                Group {
                    if let image = preview.image {
                        LargePreviewImage(
                            state: .memoryImage(
                                id: "report-\(preview.filter.rawValue)",
                                image: image,
                                aspectRatio: aspectRatio
                            ),
                            contentMode: .fit,
                            cornerRadius: 16
                        )
                    } else if preview.errorMessage != nil {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemBackground))
                            Text(preview.errorMessage ?? "")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .padding(16)
                        }
                        .aspectRatio(aspectRatio, contentMode: .fit)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemBackground))
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("プレビューを準備中…")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .aspectRatio(aspectRatio, contentMode: .fit)
                    }
                }
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

    private func previewStatusText(_ preview: ImprovementReportPreviewState) -> String {
        if preview.errorMessage != nil { return "エラー" }
        if preview.isLoading || preview.image == nil { return "生成中" }
        return "準備完了"
    }

    private func previewStatusColor(_ preview: ImprovementReportPreviewState) -> Color {
        if preview.errorMessage != nil { return .red }
        if preview.isLoading || preview.image == nil { return .secondary }
        return Color(red: 0.07, green: 0.45, blue: 0.20)
    }

    private var footerText: String {
        if viewModel.isSending {
            return "改善レポートを送信中..."
        }
        if viewModel.previews.contains(where: \.isLoading) {
            return "変換プレビューが出そろうまで送信できません。途中で戻ると、この画面はそのまま閉じます。"
        }
        if viewModel.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "コメントを入力すると送信ボタンが有効になります。"
        }
        if !viewModel.attachments.isEmpty {
            return "追加写真 \(viewModel.attachments.count) 枚も含めて送信されます。未送信のまま戻ると、この改善レポートは破棄されます。"
        }
        return "未送信のまま戻ると、この改善レポートは破棄されます。"
    }
}
