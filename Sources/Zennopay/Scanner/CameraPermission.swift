import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Camera authorization status, abstracted so the SDK and its tests don't
/// depend on `AVAuthorizationStatus` directly.
enum CameraAuthorization: Equatable {
    case authorized
    case denied
    case notDetermined
}

/// Thin wrapper over `AVCaptureDevice` authorization so the flow can branch to
/// the paste-QR fallback on denial. The host app MUST declare
/// `NSCameraUsageDescription` in its Info.plist — the SDK triggers the prompt
/// but iOS reads the usage string from the host bundle. (Documented in README.)
enum CameraPermission {

    static var current: CameraAuthorization {
        #if canImport(AVFoundation) && os(iOS)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
        #else
        return .denied
        #endif
    }

    /// Request access; resolves to the resulting authorization. On a platform
    /// without a camera (macOS test host) resolves to `.denied` so the flow
    /// falls back to paste.
    static func request() async -> CameraAuthorization {
        #if canImport(AVFoundation) && os(iOS)
        if current == .authorized { return .authorized }
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
        #else
        return .denied
        #endif
    }
}
