import SwiftUI

struct SmallPreviewImage: View {
    let fileName: String?
    let isRegenerating: Bool

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray5))
                .frame(width: 48, height: 48)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if isRegenerating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: fileName) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let fileName else {
            image = nil
            return
        }

        let loadedImage = await Task.detached(priority: .userInitiated) {
            PreviewStorageService.loadPreview(fileName: fileName, kind: .small)
        }.value
        image = loadedImage
    }
}
