import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Entry point to the Zennopay **native** checkout flow (Stripe PaymentSheet
/// model). The SDK renders the entire pay experience — QR scan → amount →
/// slide-to-confirm → result — natively, in-process, inside the host app. There
/// is NO browser, NO `ASWebAuthenticationSession`, and NO deep-link round-trip
/// on the happy path.
///
/// The host's backend pre-creates the payment intent and mints a short-lived
/// RS256 session JWT (≤5-min TTL, single-use `jti`, bound to `intent_id`,
/// `aud = zennopay-checkout`). The host hands both to the app; the SDK holds the
/// JWT in memory and sends it as `Authorization: Bearer` on each REST call.
///
/// The host MUST declare `NSCameraUsageDescription` in its Info.plist — the SDK
/// triggers the camera prompt, but iOS reads the usage string from the host
/// bundle. If the user denies camera access, the SDK falls back to a
/// paste-QR-data field.
public enum Zennopay {

#if canImport(UIKit)
    /// Present the native checkout flow modally over `from`.
    ///
    /// - Parameters:
    ///   - from: the host view controller to present over.
    ///   - intentID: the Zennopay payment intent identifier (e.g. `zp_abc123`).
    ///   - sessionJWT: the partner-backend-minted session JWT scoped to this intent.
    ///   - refreshSession: optional host hook invoked on a 401 (session
    ///     expiry). Given the intent ID, it re-mints a fresh session JWT from
    ///     the host backend (or returns nil if it can't). When nil, a 401 is
    ///     fatal. (Design decision D3=A.)
    ///   - appearance: partner theming (colors, corner radius, font, logo,
    ///     light/dark). Defaults to `.default` (the `DESIGN.md` bank-solid
    ///     look, following the system appearance). Structural rules
    ///     (radius ≤ 12, accent-as-state, tabular-nums) are not overridable.
    ///   - config: REST/base-URL configuration. Defaults to staging.
    ///   - onResult: delivered on the main queue with the final
    ///     `PaymentResult` (`.completed` / `.failed` / `.pending` /
    ///     `.canceled`) when the user closes the sheet. Terminal screens
    ///     (receipt / failure) wait for an explicit Done — no auto-dismiss.
    @MainActor
    public static func presentCheckout(
        from: UIViewController,
        intentID: String,
        sessionJWT: String,
        refreshSession: (@Sendable (String) async -> String?)? = nil,
        appearance: ZennopayAppearance = .default,
        config: ZennopayConfig = .staging,
        onResult: @escaping (PaymentResult) -> Void
    ) {
        // Fail fast on token problems BEFORE presenting any UI — the host gets
        // an immediate `.failed` rather than an empty sheet.
        guard !sessionJWT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            onResult(.failed(intentID: intentID, error: .invalidJWT))
            return
        }
        let claims: JWTClaims.Decoded
        do {
            claims = try JWTClaims.validate(jwt: sessionJWT, expectedIntentID: intentID)
        } catch let error as ZennopayError {
            onResult(.failed(intentID: intentID, error: error))
            return
        } catch {
            onResult(.failed(intentID: intentID, error: .malformedToken))
            return
        }

        presentNative(
            from: from,
            intentID: intentID,
            sessionJWT: sessionJWT,
            refreshSession: refreshSession,
            appearance: appearance,
            corridor: claims.corridor,
            config: config,
            transport: URLSession.shared,
            store: IdempotencyStore(),
            onResult: onResult
        )
    }

    // MARK: - Internal presentation (injectable transport/store for tests)

    @MainActor
    static func presentNative(
        from: UIViewController,
        intentID: String,
        sessionJWT: String,
        refreshSession: (@Sendable (String) async -> String?)?,
        appearance: ZennopayAppearance = .default,
        corridor: String? = nil,
        config: ZennopayConfig,
        transport: HTTPTransport,
        store: IdempotencyStore,
        onResult: @escaping (PaymentResult) -> Void
    ) {
        #if canImport(SwiftUI) && canImport(UIKit)
        guard #available(iOS 14.0, *) else {
            onResult(.failed(intentID: intentID, error: .presentationContextMissing))
            return
        }
        let client = RESTClient(
            config: config,
            intentID: intentID,
            sessionJWT: sessionJWT,
            refreshSession: refreshSession,
            transport: transport
        )
        // The view model delivers the result exactly once — when the user
        // closes the sheet (Done / close). Dismiss then hand the result to the
        // host on the main queue. There is NO auto-dismiss on terminal states.
        var hostVC: UIViewController?
        let wrapped: (PaymentResult) -> Void = { result in
            DispatchQueue.main.async {
                hostVC?.dismiss(animated: true) { onResult(result) }
            }
        }
        let vm = CheckoutViewModel(
            intentID: intentID,
            config: config,
            client: client,
            store: store,
            theme: ZTheme(appearance: appearance),
            corridor: corridor,
            onResult: wrapped
        )
        let root = CheckoutContainerView(vm: vm)
        let controller = UIHostingController(rootView: root)
        controller.modalPresentationStyle = .fullScreen
        hostVC = controller
        from.present(controller, animated: true)
        #else
        onResult(.failed(intentID: intentID, error: .presentationContextMissing))
        #endif
    }
#endif
}
