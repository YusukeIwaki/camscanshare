import SwiftData
import SwiftUI

struct DocumentListView: View {
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Document.updatedAt, order: .reverse) private var documents: [Document]
    @State private var viewModel = DocumentListViewModel()

    var body: some View {
        ZStack {
            if documents.isEmpty {
                emptyState
            } else {
                documentList
            }

            // FAB
            if !viewModel.isSelectionMode {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        fabButton
                    }
                }
                .padding(.trailing, 24)
                .padding(.bottom, 24)
            }
        }
        .overlay(alignment: .top) {
            if viewModel.isSelectionMode {
                selectionBar
            }
        }
        .navigationBarHidden(true)
        .alert("文書の削除", isPresented: $viewModel.showDeleteConfirmation) {
            Button("キャンセル", role: .cancel) {}
            Button("削除", role: .destructive) {
                viewModel.deleteSelected(documents: documents, modelContext: modelContext)
            }
        } message: {
            Text("選択した\(viewModel.selectedIds.count)件の文書を削除しますか？")
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .opacity(0.4)
            Text("文書がありません")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("右下のボタンからスキャンを開始しましょう")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    // MARK: - Document List

    private var documentList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if viewModel.isSelectionMode {
                    Color.clear.frame(height: 56)
                }

                ForEach(documents) { document in
                    documentRow(document)
                }
            }
            .padding(.bottom, 34) // Home indicator safe area
        }
    }

    private func documentRow(_ document: Document) -> some View {
        let isSelected = viewModel.selectedIds.contains(document.persistentModelID)
        let firstPage = document.sortedPages.first

        return HStack(spacing: 16) {
            // Thumbnail
            ZStack {
                SmallPreviewImage(
                    fileName: firstPage?.smallPreviewFileName,
                    isRegenerating: viewModel.isRegeneratingPreview(for: firstPage)
                )

                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.white)
                                .font(.title3.weight(.semibold))
                        }
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(document.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text("\(document.pages.count)ページ")
                    Circle()
                        .frame(width: 3, height: 3)
                        .opacity(0.6)
                    Text(document.updatedAt, style: .date)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onAppear {
            viewModel.ensureSmallPreview(for: firstPage, context: modelContext)
        }
        .onTapGesture {
            if viewModel.isSelectionMode {
                viewModel.toggleSelection(document.persistentModelID)
            } else {
                path.append(AppRoute.pageList(documentId: document.persistentModelID))
            }
        }
        .onLongPressGesture {
            if !viewModel.isSelectionMode {
                viewModel.enterSelectionMode(with: document.persistentModelID)
            }
        }
    }

    // MARK: - Selection Bar

    private var selectionBar: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.exitSelectionMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
            }

            Text("\(viewModel.selectedIds.count)件選択")
                .font(.system(size: 18, weight: .medium))

            Spacer()

            Button {
                viewModel.showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.title3)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(Color.accentColor)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.25), value: viewModel.isSelectionMode)
    }

    // MARK: - FAB

    private var fabButton: some View {
        Button {
            path.append(AppRoute.cameraScan(documentId: nil, retakePageId: nil))
        } label: {
            Image(systemName: "camera.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
        }
    }
}
