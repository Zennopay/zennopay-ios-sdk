#if canImport(SwiftUI) && canImport(PhotosUI) && os(iOS)
import SwiftUI
import PhotosUI
import UIKit
import CoreImage

/// A one-shot photo-library picker for choosing a QR screenshot. The picked
/// image is decoded on-device with `CIDetector(ofType: CIDetectorTypeQRCode)`
/// and the RAW decoded string is handed to `onDecode` — which routes it to the
/// SAME authoritative `POST /scan` backend parse as the live camera. A pick that
/// yields no QR calls `onDecode(nil)` so the caller can show a soft hint.
///
/// iOS-only (PhotosUI + UIImage). On macOS the SDK falls back to paste entry.
@available(iOS 14.0, *)
struct GalleryQRPicker: UIViewControllerRepresentable {
    let onDecode: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDecode: onDecode) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onDecode: (String?) -> Void
        init(onDecode: @escaping (String?) -> Void) { self.onDecode = onDecode }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else {
                onDecode(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [onDecode] object, _ in
                let decoded = (object as? UIImage).flatMap(QRImageDecoder.decode)
                DispatchQueue.main.async { onDecode(decoded) }
            }
        }
    }
}

/// Decode the first QR payload found in an image. Kept as a clean, testable
/// seam separate from the picker UI.
enum QRImageDecoder {
    static func decode(_ image: UIImage) -> String? {
        guard let ciImage = image.ciImage ?? image.cgImage.map(CIImage.init) else { return nil }
        let context = CIContext()
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) ?? []
        for case let qr as CIQRCodeFeature in features {
            if let message = qr.messageString, !message.isEmpty {
                return message
            }
        }
        return nil
    }
}
#endif
