import SwiftUI

struct LargePreviewImage: View {
    let state: PreviewDisplayState
    let contentMode: ContentMode
    let cornerRadius: CGFloat
    let placeholderSystemImage: String

    @State private var image: UIImage?

    init(
        state: PreviewDisplayState,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = 12,
        placeholderSystemImage: String = "doc.text"
    ) {
        self.state = state
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.placeholderSystemImage = placeholderSystemImage
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(.systemGray6))

            if let inMemoryImage {
                Image(uiImage: inMemoryImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholderContent
            }
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: state.cacheKey) {
            await loadImage()
        }
    }

    @ViewBuilder
    private var placeholderContent: some View {
        switch state {
        case .image:
            ProgressView()
                .controlSize(.regular)
        case .memoryImage:
            EmptyView()
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("プレビュー生成中…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        case .placeholder:
            Image(systemName: placeholderSystemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    private var aspectRatio: CGFloat {
        switch state {
        case .image(_, _, let aspectRatio), .memoryImage(_, _, let aspectRatio), .loading(let aspectRatio), .placeholder(let aspectRatio):
            aspectRatio
        }
    }

    private var inMemoryImage: UIImage? {
        guard case let .memoryImage(_, image, _) = state else { return nil }
        return image
    }

    private func loadImage() async {
        guard case let .image(fileName, kind, _) = state else {
            image = nil
            return
        }

        let loadedImage = await Task.detached(priority: .userInitiated) {
            switch kind {
            case .small:
                PreviewStorageService.loadPreview(fileName: fileName, kind: .small)
            case .large:
                PreviewStorageService.loadPreview(fileName: fileName, kind: .large)
            case .working:
                WorkingPreviewStorageService.loadWorkingPreview(fileName: fileName)
            }
        }.value
        image = loadedImage
    }
}

private extension PreviewDisplayState {
    var cacheKey: String {
        switch self {
        case let .image(fileName, kind, _):
            "\(kind.rawValue)|\(fileName)"
        case let .memoryImage(id, _, _):
            "memory|\(id)"
        case let .loading(aspectRatio):
            "loading|\(aspectRatio)"
        case let .placeholder(aspectRatio):
            "placeholder|\(aspectRatio)"
        }
    }
}
