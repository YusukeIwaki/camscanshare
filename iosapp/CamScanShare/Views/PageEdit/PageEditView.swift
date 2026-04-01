import SwiftData
import SwiftUI

struct PageEditView: View {
    let documentId: PersistentIdentifier
    let initialPageIndex: Int
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = PageEditViewModel()

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
        .alert("編集内容を破棄しますか？", isPresented: $viewModel.showDiscardDialog) {
            Button("キャンセル", role: .cancel) {}
            Button("破棄", role: .destructive) {
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
                viewModel.apply(context: modelContext)
                path.removeLast()
            } label: {
                Text("適用")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .foregroundStyle(Color.accentColor)
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
            let editState = index < viewModel.editStates.count ? viewModel.editStates[index] : nil
            let pageAspectRatio = ImageStorageService.imageAspectRatio(fileName: page.originalImageFileName) ?? 1.0

            AsyncPagePreview(
                fileName: page.originalImageFileName,
                editState: editState,
                pageAspectRatio: pageAspectRatio
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
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
        // Simple visual representation of the filter effect
        VStack(spacing: 3) {
            ForEach(0..<6, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.gray.opacity(filterOpacity(for: preset)))
                    .frame(height: i == 0 ? 3 : 2)
                    .frame(maxWidth: i == 0 ? 32 : CGFloat([44, 36, 48, 34, 42][i - 1]))
            }
        }
        .padding(6)
    }

    private func filterOpacity(for preset: FilterPreset) -> Double {
        switch preset {
        case .original: 0.5
        case .sharpen: 0.7
        case .bw: 0.9
        case .magic: 0.8
        case .whiteboard: 0.3
        case .vivid: 0.6
        }
    }
}

private enum PagePreviewCache {
    nonisolated(unsafe) static let imageCache = NSCache<NSString, UIImage>()
}

private struct AsyncPagePreview: View {
    let fileName: String
    let editState: PageEditState?
    let pageAspectRatio: CGFloat

    @State private var renderedImage: UIImage?
    @State private var isLoading = false
    @State private var activeRenderKey = ""

    init(fileName: String, editState: PageEditState?, pageAspectRatio: CGFloat) {
        self.fileName = fileName
        self.editState = editState
        self.pageAspectRatio = pageAspectRatio

        let key = Self.makeRenderKey(fileName: fileName, editState: editState)
        let cached = Self.cachedImage(for: key)
        _renderedImage = State(initialValue: cached)
        _isLoading = State(initialValue: editState != nil && cached == nil)
        _activeRenderKey = State(initialValue: key)
    }

    private var renderKey: String {
        Self.makeRenderKey(fileName: fileName, editState: editState)
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemGray5))
                .aspectRatio(pageAspectRatio, contentMode: .fit)

            if let renderedImage {
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("フィルタを適用中…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .onAppear {
            syncStateFromCache(for: renderKey)
        }
        .onChange(of: renderKey) { _, newKey in
            syncStateFromCache(for: newKey)
        }
        .task(id: renderKey) {
            renderPreview()
        }
    }

    @MainActor
    private func renderPreview() {
        guard let editState else {
            renderedImage = nil
            isLoading = false
            activeRenderKey = renderKey
            return
        }

        activeRenderKey = renderKey

        if let cached = PagePreviewCache.imageCache.object(forKey: renderKey as NSString) {
            renderedImage = cached
            isLoading = false
            return
        }

        renderedImage = nil
        isLoading = true

        let requestKey = renderKey
        let fileName = fileName
        let filterPreset = editState.filterPreset
        let rotationDegrees = editState.rotationDegrees

        DispatchQueue.global(qos: .userInitiated).async {
            let image = ImageStorageService.loadImage(fileName: fileName)
            let filtered = image.flatMap {
                ImageFilterService.applyFilter(
                    filterPreset,
                    to: $0,
                    rotation: rotationDegrees,
                    intent: .preview
                )
            }

            if let filtered {
                PagePreviewCache.imageCache.setObject(filtered, forKey: requestKey as NSString)
            }

            DispatchQueue.main.async {
                guard activeRenderKey == requestKey else { return }
                renderedImage = filtered
                isLoading = false
            }
        }
    }

    @MainActor
    private func syncStateFromCache(for key: String) {
        activeRenderKey = key
        let cached = Self.cachedImage(for: key)
        renderedImage = cached
        isLoading = editState != nil && cached == nil
    }

    private static func makeRenderKey(fileName: String, editState: PageEditState?) -> String {
        guard let editState else { return "\(fileName)|missing" }
        return "\(fileName)|\(editState.filterPreset.rawValue)|\(editState.rotationDegrees)"
    }

    private static func cachedImage(for key: String) -> UIImage? {
        PagePreviewCache.imageCache.object(forKey: key as NSString)
    }
}
