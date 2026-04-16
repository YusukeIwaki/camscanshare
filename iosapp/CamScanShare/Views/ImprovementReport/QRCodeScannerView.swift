import SwiftUI
import VisionKit

struct QRCodeScannerSheet: View {
    let onScanned: (String) -> Void
    let onFailure: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            QRCodeScannerRepresentable(onScanned: onScanned, onFailure: onFailure)
                .ignoresSafeArea()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 20)
            .padding(.leading, 16)
        }
        .interactiveDismissDisabled()
    }
}

private struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScanned: onScanned, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        guard !context.coordinator.started else { return }
        context.coordinator.started = true

        guard DataScannerViewController.isSupported, DataScannerViewController.isAvailable else {
            onFailure("QRコードリーダーを起動できませんでした。")
            return
        }

        do {
            try uiViewController.startScanning()
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    static func dismantleUIViewController(
        _ uiViewController: DataScannerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScanned: (String) -> Void
        let onFailure: (String) -> Void
        var started = false
        private var finished = false

        init(onScanned: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onScanned = onScanned
            self.onFailure = onFailure
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !finished else { return }

            for item in addedItems {
                guard case .barcode(let barcode) = item,
                    let payload = barcode.payloadStringValue,
                    !payload.isEmpty
                else {
                    continue
                }

                finished = true
                onScanned(payload)
                return
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            guard !finished else { return }
            finished = true
            onFailure(error.localizedDescription)
        }
    }
}
