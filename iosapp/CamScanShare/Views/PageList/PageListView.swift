import SwiftData
import SwiftUI

struct PageListView: View {
    let documentId: PersistentIdentifier
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = PageListViewModel()
    @State private var orderedPageIDs: [PersistentIdentifier] = []
    @State private var pageFrames: [PersistentIdentifier: CGRect] = [:]
    @State private var dragState: DragState?

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 0) {
                    topAppBar
                    pageGrid(containerHeight: geometry.size.height)
                }

                if dragState == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            addPageFAB
                        }
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                    .transition(.scale.combined(with: .opacity))
                }

                deleteZone

                if let draggedPage = draggedPage {
                    draggingOverlay(for: draggedPage)
                }
            }
            .coordinateSpace(name: "PageListRoot")
            .navigationBarHidden(true)
            .background(InteractivePopGestureEnabler())
            .onAppear {
                viewModel.loadDocument(id: documentId, context: modelContext)
                syncOrderedPages()
            }
            .onChange(of: viewModel.sortedPages.map(\.persistentModelID)) { _, _ in
                syncOrderedPages()
            }
            .onPreferenceChange(PageFramePreferenceKey.self) { frames in
                pageFrames = frames
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: orderedPageIDs)
            .animation(.easeInOut(duration: 0.2), value: dragState != nil)
            .alert("名前を変更", isPresented: $viewModel.showRenameDialog) {
                TextField("文書名", text: $viewModel.renameText)
                Button("キャンセル", role: .cancel) {}
                Button("変更") {
                    viewModel.rename(context: modelContext)
                }
            }
            .sheet(isPresented: $viewModel.showShareSheet) {
                if let url = viewModel.pdfURL {
                    ShareSheetView(items: [url])
                }
            }
        }
    }

    // MARK: - Top App Bar

    private var topAppBar: some View {
        HStack(spacing: 4) {
            Button {
                path.removeLast()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .foregroundStyle(.primary)

            Button {
                viewModel.renameText = viewModel.document?.name ?? ""
                viewModel.showRenameDialog = true
            } label: {
                HStack(spacing: 6) {
                    Text(viewModel.document?.name ?? "")
                        .font(.system(size: 18, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)

            Spacer()

            Button {
                viewModel.generateAndSharePDF()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.title3)
                    .frame(width: 40, height: 40)
            }
            .foregroundStyle(Color.accentColor)
            .disabled(viewModel.isGeneratingPDF)
        }
        .padding(.horizontal, 8)
        .frame(height: 64)
        .background(Color(.systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Page Grid

    private func pageGrid(containerHeight: CGFloat) -> some View {
        ScrollView {
            if viewModel.sortedPages.isEmpty {
                emptyState
                    .padding(.top, 80)
                    .padding(.horizontal, 24)
            } else {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(orderedPages.enumerated()), id: \.element.persistentModelID) { index, page in
                        pageCard(page: page, index: index, containerHeight: containerHeight)
                    }
                }
                .padding(16)
                .padding(.bottom, 72) // Space for FAB
            }
        }
        .scrollDisabled(dragState != nil)
    }

    private func pageCard(page: Page, index: Int, containerHeight: CGFloat) -> some View {
        let isDraggedPage = dragState?.pageID == page.persistentModelID

        return pageCardBody(page: page, index: index, isPlaceholder: isDraggedPage)
        .overlay {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PageFramePreferenceKey.self,
                    value: [page.persistentModelID: proxy.frame(in: .named("PageListRoot"))]
                )
            }
        }
        .onTapGesture {
            guard dragState == nil else { return }
            path.append(AppRoute.pageEdit(documentId: documentId, initialPageIndex: index))
        }
        .gesture(reorderGesture(for: page, containerHeight: containerHeight))
        .allowsHitTesting(dragState == nil || isDraggedPage)
    }

    private func pageCardBody(page: Page, index: Int, isPlaceholder: Bool = false) -> some View {
        let pageAspectRatio = ImageStorageService.imageAspectRatio(fileName: page.originalImageFileName) ?? 1.0

        return VStack(spacing: 0) {
            Group {
                if isPlaceholder {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6).opacity(0.3))
                        .aspectRatio(pageAspectRatio, contentMode: .fit)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(
                                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                                )
                                .foregroundStyle(Color.accentColor.opacity(0.7))
                        }
                        .overlay {
                            Image(systemName: "doc.on.doc")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        }
                } else {
                    if let thumb = ImageStorageService.thumbnail(
                        fileName: page.originalImageFileName,
                        size: CGSize(width: 300, height: 420)
                    ) {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(pageAspectRatio, contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(.systemGray6))
                            .aspectRatio(pageAspectRatio, contentMode: .fit)
                            .overlay {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            Text("\(index + 1)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .opacity(0.4)
            Text("ページがありません")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("右下のボタンからページを追加できます")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Add Page FAB

    private var addPageFAB: some View {
        Button {
            path.append(AppRoute.cameraScan(documentId: documentId, retakePageId: nil))
        } label: {
            Image(systemName: "photo.badge.plus")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
        }
    }

    private var orderedPages: [Page] {
        let pagesByID = Dictionary(uniqueKeysWithValues: viewModel.sortedPages.map { ($0.persistentModelID, $0) })
        let ordered = orderedPageIDs.compactMap { pagesByID[$0] }
        let missing = viewModel.sortedPages.filter { !orderedPageIDs.contains($0.persistentModelID) }
        return ordered + missing
    }

    private var draggedPage: Page? {
        guard let pageID = dragState?.pageID else { return nil }
        return viewModel.sortedPages.first { $0.persistentModelID == pageID }
    }

    @ViewBuilder
    private var deleteZone: some View {
        VStack {
            Spacer()
            if let dragState {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.title3)
                    Text("ここにドロップして削除")
                        .font(.system(size: 15, weight: .medium))
                }
                .foregroundStyle(dragState.isOverDeleteZone ? .white : Color.red)
                .frame(maxWidth: .infinity)
                .frame(height: 80)
                .background(dragState.isOverDeleteZone ? Color.red : Color.red.opacity(0.14))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func draggingOverlay(for page: Page) -> some View {
        if let dragState {
            pageCardBody(page: page, index: dragIndexDisplay(for: page))
                .frame(width: dragState.initialFrame.width, height: dragState.initialFrame.height)
                .scaleEffect(1.08)
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 6)
                .rotationEffect(.degrees(dragState.isOverDeleteZone ? -6 : 0))
                .position(
                    x: dragState.initialFrame.midX + dragState.translation.width,
                    y: dragState.initialFrame.midY + dragState.translation.height
                )
                .zIndex(10)
                .allowsHitTesting(false)
            }
    }

    private func dragIndexDisplay(for page: Page) -> Int {
        orderedPages.firstIndex(where: { $0.persistentModelID == page.persistentModelID }).map { $0 + 1 } ?? 1
    }

    private func reorderGesture(for page: Page, containerHeight: CGFloat) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("PageListRoot")))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }

                if dragState == nil {
                    beginDragging(pageID: page.persistentModelID, startLocation: drag.startLocation)
                }

                updateDragging(location: drag.location, translation: drag.translation, containerHeight: containerHeight)
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                finishDragging(location: drag.location, containerHeight: containerHeight)
            }
    }

    private func beginDragging(pageID: PersistentIdentifier, startLocation: CGPoint) {
        guard let frame = pageFrames[pageID] else { return }
        if orderedPageIDs.isEmpty {
            syncOrderedPages()
        }

        dragState = DragState(
            pageID: pageID,
            initialFrame: frame,
            startLocation: startLocation,
            currentLocation: startLocation,
            translation: .zero,
            isOverDeleteZone: false
        )
    }

    private func updateDragging(location: CGPoint, translation: CGSize, containerHeight: CGFloat) {
        guard var dragState else { return }
        dragState.currentLocation = location
        dragState.translation = translation
        dragState.isOverDeleteZone = dragState.deleteProbeY >= containerHeight - 80
        self.dragState = dragState

        guard !dragState.isOverDeleteZone else { return }
        reorderDraggedPageIfNeeded(using: dragState)
    }

    private func finishDragging(location: CGPoint, containerHeight: CGFloat) {
        guard var dragState else { return }
        dragState.currentLocation = location
        dragState.isOverDeleteZone = dragState.deleteProbeY >= containerHeight - 80

        let draggedPageID = dragState.pageID
        let shouldDelete = dragState.isOverDeleteZone
        self.dragState = nil

        if shouldDelete {
            if let page = viewModel.sortedPages.first(where: { $0.persistentModelID == draggedPageID }) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    orderedPageIDs.removeAll { $0 == draggedPageID }
                }
                viewModel.deletePage(page, context: modelContext)
                syncOrderedPages()
            }
            return
        }

        viewModel.reorderPages(orderedPageIDs, context: modelContext)
        syncOrderedPages()
    }

    private func reorderDraggedPageIfNeeded(using dragState: DragState) {
        guard let currentIndex = orderedPageIDs.firstIndex(of: dragState.pageID) else { return }
        let dragCenter = CGPoint(
            x: dragState.initialFrame.midX + dragState.translation.width,
            y: dragState.initialFrame.midY + dragState.translation.height
        )

        let candidateIndex = orderedPageIDs.enumerated()
            .filter { $0.element != dragState.pageID }
            .compactMap { index, pageID -> Int? in
                guard let frame = pageFrames[pageID] else { return nil }
                let activationFrame = frame.insetBy(dx: -12, dy: -12)
                return activationFrame.contains(dragCenter) ? index : nil
            }
            .first

        guard let targetIndex = candidateIndex, targetIndex != currentIndex else { return }

        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            var updated = orderedPageIDs
            let moved = updated.remove(at: currentIndex)
            updated.insert(moved, at: targetIndex)
            orderedPageIDs = updated
        }
    }

    private func syncOrderedPages() {
        guard dragState == nil else { return }
        orderedPageIDs = viewModel.sortedPages.map(\.persistentModelID)
    }
}

// MARK: - Share Sheet

struct ShareSheetView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InteractivePopGestureEnablerController {
        InteractivePopGestureEnablerController()
    }

    func updateUIViewController(
        _ uiViewController: InteractivePopGestureEnablerController,
        context: Context
    ) {}
}

private final class InteractivePopGestureEnablerController: UIViewController {
    private weak var previousDelegate: UIGestureRecognizerDelegate?
    private var capturedDelegate = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        guard let navigationController,
            let interactivePopGestureRecognizer = navigationController.interactivePopGestureRecognizer
        else { return }

        if !capturedDelegate {
            previousDelegate = interactivePopGestureRecognizer.delegate
            capturedDelegate = true
        }

        interactivePopGestureRecognizer.isEnabled = navigationController.viewControllers.count > 1
        interactivePopGestureRecognizer.delegate = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)

        guard let navigationController,
            let interactivePopGestureRecognizer = navigationController.interactivePopGestureRecognizer,
            capturedDelegate
        else { return }

        interactivePopGestureRecognizer.delegate = previousDelegate
    }
}

private struct DragState {
    let pageID: PersistentIdentifier
    let initialFrame: CGRect
    let startLocation: CGPoint
    var currentLocation: CGPoint
    var translation: CGSize
    var isOverDeleteZone: Bool

    var draggedCenterY: CGFloat {
        initialFrame.midY + translation.height
    }

    var deleteProbeY: CGFloat {
        max(draggedCenterY, currentLocation.y)
    }
}

private struct PageFramePreferenceKey: PreferenceKey {
    static let defaultValue: [PersistentIdentifier: CGRect] = [:]

    static func reduce(value: inout [PersistentIdentifier: CGRect], nextValue: () -> [PersistentIdentifier: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
