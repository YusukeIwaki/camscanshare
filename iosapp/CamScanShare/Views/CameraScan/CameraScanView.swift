import SwiftData
import SwiftUI

struct CameraScanView: View {
    let existingDocumentId: PersistentIdentifier?
    let retakePageId: PersistentIdentifier?
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = CameraScanViewModel()
    @State private var showFlash = false
    @State private var showReportChip = false
    @State private var reportCaptureArmed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                // Camera preview
                CameraPreviewView(session: viewModel.session)
                    .ignoresSafeArea()

                // Detection overlay
                DetectionOverlayView(
                    rectangle: viewModel.detectedRectangle,
                    previewSize: UIScreen.main.bounds.size,
                    imageAspectRatio: viewModel.previewImageAspectRatio
                )
                .ignoresSafeArea()

                // Bottom controls
                VStack {
                    Spacer()
                    bottomControls(bottomInset: geometry.safeAreaInsets.bottom)
                }
                .ignoresSafeArea(edges: .bottom)

                reportChip(topInset: geometry.safeAreaInsets.top)

                // Flash effect
                if showFlash {
                    Color.white
                        .ignoresSafeArea()
                        .opacity(0.9)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .bottomBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .bottomBar)
        .onAppear {
            viewModel.setupCamera()
            viewModel.startSession()
        }
        .onDisappear {
            viewModel.stopSession()
        }
        .task {
            showReportChip = false
            reportCaptureArmed = false
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                showReportChip = true
            }
        }
    }

    // MARK: - Bottom Controls

    private func bottomControls(bottomInset: CGFloat) -> some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 160 + bottomInset)
            .allowsHitTesting(false)

            HStack {
                // Left action area
                leftAction
                    .frame(width: 52, height: 52)

                Spacer()

                // Capture button
                captureButton

                Spacer()

                // Right spacer for centering
                Color.clear
                    .frame(width: 52, height: 52)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, max(20, bottomInset))
        }
    }

    // MARK: - Left Action

    @ViewBuilder
    private var leftAction: some View {
        if viewModel.pageCount == 0 {
            // Close button
            Button {
                path.removeLast()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.white.opacity(0.25), lineWidth: 1.5)
                        )
                    Image(systemName: "xmark")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
        } else {
            // Thumbnail stack
            Button {
                Task { await finishScanning() }
            } label: {
                ZStack {
                    // Stack effect (background cards)
                    if viewModel.pageCount > 1 {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray5))
                            .frame(width: 52, height: 52)
                            .rotationEffect(.degrees(-5))
                            .offset(x: -2, y: -2)
                    }

                    // Latest thumbnail
                    if let thumb = viewModel.latestThumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.8), lineWidth: 2)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray5))
                            .frame(width: 52, height: 52)
                    }

                    // Page count badge
                    Text("\(viewModel.pageCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.accentColor, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 1)
                        .offset(x: 20, y: -20)
                }
            }
        }
    }

    // MARK: - Capture Button

    private var captureButton: some View {
        Button {
            Task { await capture() }
        } label: {
            ZStack {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(.white)
                    .frame(width: 58, height: 58)
            }
        }
        .disabled(viewModel.isCapturing || viewModel.isFinalizing)
    }

    @ViewBuilder
    private func reportChip(topInset: CGFloat) -> some View {
        if showReportChip {
            VStack {
                HStack {
                    Spacer()
                    Button {
                        reportCaptureArmed.toggle()
                    } label: {
                        Text("開発元に報告")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                reportCaptureArmed
                                    ? Color.accentColor
                                    : Color.black.opacity(0.58),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(reportCaptureArmed ? 0.72 : 0.32), lineWidth: 1)
                            )
                    }
                    .disabled(viewModel.isCapturing || viewModel.isFinalizing)
                    .padding(.trailing, 16)
                }
                .padding(.top, max(52, topInset + 16))

                Spacer()
            }
            .transition(.opacity)
        }
    }

    // MARK: - Actions

    private func capture() async {
        let captureForReport = reportCaptureArmed
        reportCaptureArmed = false

        // Flash effect
        withAnimation(.easeOut(duration: 0.1)) { showFlash = true }
        try? await Task.sleep(for: .milliseconds(100))
        withAnimation(.easeOut(duration: 0.3)) { showFlash = false }

        guard let image = await viewModel.capturePhoto() else { return }
        viewModel.processAndStoreCapturedImage(image, isDebugCapture: captureForReport)

        if retakePageId != nil {
            await finishScanning()
        }
    }

    private func finishScanning() async {
        guard !viewModel.isFinalizing else { return }
        guard !viewModel.capturedPages.isEmpty else {
            if path.count > 0 {
                path.removeLast()
            }
            return
        }

        viewModel.isFinalizing = true
        defer { viewModel.isFinalizing = false }

        if let retakePageId {
            await replaceRetakePage(retakePageId)
            if path.count > 0 {
                path.removeLast()
            }
            return
        }

        let document = resolveDocumentForCapturedPages()
        let startOrder = document.pages.count
        for (index, capturedPage) in viewModel.capturedPages.enumerated() {
            let fileName = ImageStorageService.saveImage(capturedPage.image)
            let previewFiles = try? await PreviewGenerationCoordinator.shared.generatePersistedPreviews(
                sourceFileName: fileName,
                filter: .original,
                rotation: 0
            )
            let page = Page(
                document: document,
                sortOrder: startOrder + index,
                originalImageFileName: fileName,
                smallPreviewFileName: previewFiles?.smallFileName,
                largePreviewFileName: previewFiles?.largeFileName,
                isDebugCapture: capturedPage.isDebugCapture,
                debugCaptureId: capturedPage.debugCaptureId
            )
            modelContext.insert(page)
        }

        document.updatedAt = .now
        try? modelContext.save()

        if existingDocumentId != nil {
            if path.count > 0 {
                path.removeLast()
            }
        } else {
            path = NavigationPath()
            path.append(AppRoute.pageList(documentId: document.persistentModelID))
        }
    }

    private func resolveDocumentForCapturedPages() -> Document {
        if let existingDocumentId,
            let existing = modelContext.model(for: existingDocumentId) as? Document
        {
            return existing
        }

        let document = Document()
        modelContext.insert(document)
        return document
    }

    private func replaceRetakePage(_ pageId: PersistentIdentifier) async {
        guard let replacementPage = viewModel.capturedPages.last,
            let page = modelContext.model(for: pageId) as? Page
        else { return }

        let oldFileName = page.originalImageFileName
        let oldSmallPreviewFileName = page.smallPreviewFileName
        let oldLargePreviewFileName = page.largePreviewFileName
        let newFileName = ImageStorageService.saveImage(replacementPage.image)
        page.originalImageFileName = newFileName
        page.isDebugCapture = replacementPage.isDebugCapture
        page.debugCaptureId = replacementPage.debugCaptureId

        do {
            let previewFiles = try await PreviewGenerationCoordinator.shared.generatePersistedPreviews(
                sourceFileName: newFileName,
                filter: page.filterPreset,
                rotation: page.rotationDegrees
            )
            page.smallPreviewFileName = previewFiles.smallFileName
            page.largePreviewFileName = previewFiles.largeFileName
        } catch {
            page.smallPreviewFileName = nil
            page.largePreviewFileName = nil
        }

        page.document?.updatedAt = .now
        try? modelContext.save()
        ImageStorageService.deleteImage(fileName: oldFileName)
        PreviewStorageService.deletePreview(fileName: oldSmallPreviewFileName, kind: .small)
        PreviewStorageService.deletePreview(fileName: oldLargePreviewFileName, kind: .large)
        WorkingPreviewStorageService.deleteWorkingPreviews(sourceFileName: oldFileName)
    }
}
