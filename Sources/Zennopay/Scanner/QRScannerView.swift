#if canImport(SwiftUI) && canImport(AVFoundation) && os(iOS)
import SwiftUI
import AVFoundation

/// A live AVFoundation QR scanner as a SwiftUI view. Emits the RAW decoded
/// string via `onCode`; the caller (CheckoutViewModel) submits it to `/scan`.
/// On-device decode uses `AVCaptureMetadataOutput` with `.qr` — no Vision
/// dependency needed for the common case, and it runs on the capture queue.
///
/// The host app must declare `NSCameraUsageDescription`. If permission is
/// denied the SDK shows the paste fallback instead of this view.
@available(iOS 13.0, *)
struct QRScannerView: UIViewRepresentable {
    /// Called once per distinct decode. The view debounces duplicates so a
    /// single QR in frame fires exactly one submit.
    let onCode: (String) -> Void
    /// Desired torch state. Applied to the running session's capture device.
    var torchOn: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setTorch(torchOn)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: Preview view backed by an AVCaptureVideoPreviewLayer

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "com.zennopay.scanner.session")
        private var lastCode: String?
        /// The capture device backing the running session — retained so the
        /// torch can be toggled without re-querying `AVCaptureDevice.default`.
        private var captureDevice: AVCaptureDevice?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        /// Toggle the torch on the running session's device. No-op if the device
        /// has no torch (front-camera-only / Simulator) or lock fails.
        func setTorch(_ on: Bool) {
            sessionQueue.async { [weak self] in
                guard let device = self?.captureDevice, device.hasTorch,
                      device.isTorchAvailable else { return }
                let desired: AVCaptureDevice.TorchMode = on ? .on : .off
                guard device.torchMode != desired else { return }
                do {
                    try device.lockForConfiguration()
                    device.torchMode = desired
                    device.unlockForConfiguration()
                } catch {
                    // Torch is a nicety; never fail the scan flow over it.
                }
            }
        }

        func attach(to view: PreviewView) {
            view.previewLayer.session = session
            view.previewLayer.videoGravity = .resizeAspectFill
            sessionQueue.async { [weak self] in self?.configureAndStart() }
        }

        private func configureAndStart() {
            session.beginConfiguration()
            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            captureDevice = device

            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: sessionQueue)
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            session.startRunning()
        }

        func stop() {
            sessionQueue.async { [weak self] in
                guard let self, self.session.isRunning else { return }
                self.session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard
                let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                obj.type == .qr,
                let raw = obj.stringValue,
                raw != lastCode
            else { return }
            lastCode = raw
            DispatchQueue.main.async { [onCode] in onCode(raw) }
        }
    }
}
#endif
