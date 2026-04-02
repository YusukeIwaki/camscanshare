import SwiftData
import SwiftUI

struct PageEditView: View {
    let documentId: PersistentIdentifier
    let initialPageIndex: Int
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = PageEditViewModel()
    @State private var workingPreviewManager = WorkingPreviewManager()

    var body: some View {
        VStack(spacing: 0) {
            topAppBar
            pagePreview
            actionToolbar
            filterPanel
        }
        .navigationBarHidden(true)
        .onAppear {
            viewModel.loadDocument(id: documentId, initialPageIndex: initialPageIndex, context: modelContext)
        }
        .onDisappear {
            workingPreviewManager.clearPreview()
        }
        .task(id: viewModel.currentPreviewRequestKey) {
            await updateCurrentPreviewState()
        }
        .alert("編集内容を破棄しますか？", isPresented: $viewModel.showDiscardDialog) {
            Button("キャンセル", role: .cancel) {}
            Button("破棄", role: .destructive) {
                if let currentPage = viewModel.currentPage {
                    workingPreviewManager.clearPreview(sourceFileName: currentPage.originalImageFileName)
                } else {
                    workingPreviewManager.clearPreview()
                }
                viewModel.discardChanges()
                path.removeLast()
            }
        } message: {
            Text("変更した回転やフィルタの設定は保存されません。")
        }
        .alert("全ページに適用", isPresented: $viewModel.showApplyAllFilterDialog) {
            Button("キャンセル", role: .cancel) {
                viewModel.pendingApplyAllFilter = nil
            }
            Button("適用") {
                if let filter = viewModel.pendingApplyAllFilter {
                    viewModel.setFilterForAllPages(filter)
                }
                viewModel.pendingApplyAllFilter = nil
            }
        } message: {
            if let filter = viewModel.pendingApplyAllFilter {
                Text("「\(filter.displayName)」フィルタを全ページに適用しますか？")
            }
        }
    }

    // MARK: - Top App Bar

    private var topAppBar: some View {
        HStack(spacing: 4) {
            Button {
                if viewModel.isDirty {
                    viewModel.showDiscardDialog = true
                } else {
                    path.removeLast()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .foregroundStyle(.primary)

            Text("ページ編集")
                .font(.system(size: 18, weight: .medium))

            Spacer()

            Button {
                Task {
                    await viewModel.apply(
                        context: modelContext,
                        currentWorkingPreviewImage: workingPreviewManager.supportsPersistedReuse
                            ? workingPreviewManager.previewImage : nil,
                        currentWorkingPreviewRequestKey: workingPreviewManager.supportsPersistedReuse
                            ? workingPreviewManager.previewRequestKey : nil
                    )
                    if let currentPage = viewModel.currentPage {
                        workingPreviewManager.clearPreview(sourceFileName: currentPage.originalImageFileName)
                    } else {
                        workingPreviewManager.clearPreview()
                    }
                    path.removeLast()
                }
            } label: {
                Group {
                    if viewModel.isApplying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("適用")
                            .font(.system(size: 15, weight: .medium))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .foregroundStyle(Color.accentColor)
            .disabled(viewModel.isApplying)
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Page Preview

    private var pagePreview: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $viewModel.currentPageIndex) {
                ForEach(Array(viewModel.pages.enumerated()), id: \.element.persistentModelID) {
                    index, page in
                    pagePreviewItem(page: page, index: index)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color(.systemGray6))

            // Page indicator
            Text("\(viewModel.currentPageIndex + 1) / \(viewModel.totalPages)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 8)
        }
    }

    private func pagePreviewItem(page: Page, index: Int) -> some View {
        GeometryReader { geometry in
            let pageAspectRatio =
                PreviewStorageService.imageAspectRatio(fileName: page.largePreviewFileName, kind: .large)
                ?? ImageStorageService.imageAspectRatio(fileName: page.originalImageFileName)
                ?? 1.0

            LargePreviewImage(
                state: previewDisplayState(for: page, index: index, aspectRatio: pageAspectRatio),
                contentMode: .fit,
                cornerRadius: 4
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .onAppear {
                if index == viewModel.currentPageIndex {
                    viewModel.ensurePersistedPreview(for: page, context: modelContext)
                }
            }
        }
    }

    // MARK: - Action Toolbar

    private var actionToolbar: some View {
        HStack {
            toolbarButton(icon: "rotate.left", label: "左90°回転") {
                viewModel.rotateCurrentPage()
            }

            Spacer()

            toolbarButton(icon: "camera", label: "撮り直し") {
                guard let pageId = viewModel.currentPageId else { return }
                path.append(AppRoute.cameraScan(documentId: documentId, retakePageId: pageId))
            }

            Spacer()

            toolbarButton(
                icon: "slider.horizontal.3", label: "フィルタ",
                isActive: viewModel.showFilterPanel
            ) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewModel.showFilterPanel.toggle()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func toolbarButton(
        icon: String, label: String, isActive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(isActive ? Color.accentColor : .secondary)
            .frame(minWidth: 64)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Filter Panel

    private var filterPanel: some View {
        Group {
            if viewModel.showFilterPanel {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("フィルタを選択")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("長押しで全ページに適用")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(FilterPreset.allCases) { preset in
                                filterItemView(preset: preset)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
                .background(Color(.systemBackground))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func filterItemView(preset: FilterPreset) -> some View {
        let isActive = viewModel.currentEditState?.filterPreset == preset

        return Button {
            viewModel.setFilter(preset)
        } label: {
            VStack(spacing: 6) {
                // Filter preview thumbnail
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.systemGray6))
                    .frame(width: 64, height: 80)
                    .overlay {
                        filterPreviewContent(preset: preset)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isActive ? Color.accentColor : .clear, lineWidth: 2)
                    )

                Text(preset.displayName)
                    .font(.system(size: 11, weight: isActive ? .bold : .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    viewModel.pendingApplyAllFilter = preset
                    viewModel.showApplyAllFilterDialog = true
                }
        )
    }

    @ViewBuilder
    private func filterPreviewContent(preset: FilterPreset) -> some View {
        Image(preset.thumbnailAssetName)
            .resizable()
            .scaledToFill()
            .frame(width: 64, height: 80)
            .clipped()
    }

    private func previewDisplayState(
        for page: Page,
        index: Int,
        aspectRatio: CGFloat
    ) -> PreviewDisplayState {
        if index == viewModel.currentPageIndex {
            return .pageEditor(
                persistedLargePreviewFileName: page.largePreviewFileName,
                workingPreviewImage: workingPreviewManager.previewImage,
                workingPreviewID: workingPreviewManager.previewRequestKey,
                aspectRatio: aspectRatio,
                isGeneratingWorkingPreview: workingPreviewManager.isGenerating
                    || viewModel.isRegeneratingPersistedPreview(for: page)
            )
        }

        return .pageEditor(
            persistedLargePreviewFileName: page.largePreviewFileName,
            workingPreviewImage: nil,
            workingPreviewID: nil,
            aspectRatio: aspectRatio,
            isGeneratingWorkingPreview: viewModel.isRegeneratingPersistedPreview(for: page)
        )
    }

    @MainActor
    private func updateCurrentPreviewState() async {
        guard let currentPage = viewModel.currentPage else {
            workingPreviewManager.clearPreview()
            return
        }

        viewModel.ensurePersistedPreview(for: currentPage, context: modelContext)
        await workingPreviewManager.updatePreview(
            for: currentPage,
            editState: viewModel.currentEditState,
            savedState: viewModel.currentSavedState
        )
    }
}
