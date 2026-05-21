import Foundation
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Entry point to the Zennopay checkout flow.
///
/// Modeled on the Stripe Checkout pattern: the host application (e.g. Wizz)
/// hands the SDK a payment intent identifier and a short-lived JWT it
/// previously obtained from its own backend. The SDK opens the Zennopay
/// hosted checkout in a system browser tab via `ASWebAuthenticationSession`
/// so the user always sees a real URL bar and an Apple-mediated consent
/// sheet on first launch. When the user completes or cancels the flow, the
/// checkout web redirects to `{returnScheme}://payment-result?...` and the
/// SDK delivers a `PaymentResult` to the host.
public enum Zennopay {

    // MARK: - Public API

    /// Open the Zennopay checkout for the given intent.
    ///
    /// - Parameters:
    ///   - intentID: The Zennopay payment intent identifier (e.g. `zp_abc123`).
    ///   - jwt: A short-lived JWT issued to the host's backend, scoped to this
    ///     intent. Passed in the URL fragment so it never hits server logs.
    ///   - returnScheme: The URL scheme the host has registered in its
    ///     `Info.plist`, without the `://`. Example: `"wizz"`.
    ///   - presentationContext: The window to present the auth session over.
    ///     If `nil`, the SDK will try to find the host app's key window.
    ///   - completion: Delivered on the main queue with either a
    ///     `PaymentResult` or a `ZennopayError`.
    public static func openCheckout(
        intentID: String,
        jwt: String,
        returnScheme: String,
        presentationContext: ASPresentationAnchor? = nil,
        completion: @escaping (Result<PaymentResult, ZennopayError>) -> Void
    ) {
        // Up-front validation. JWT structure is checked minimally — the
        // checkout web is the real authority on token validity.
        guard !jwt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dispatchMain { completion(.failure(.invalidJWT)) }
            return
        }

        // P1 security gate: the JWT must be bound to *this* intent.
        // We inspect (do not verify) the JWT payload and fail fast on
        // intent mismatch, expiry, or structural problems so we never
        // open the system browser — and therefore never leak the
        // intent ID into a URL — with a token we already know is bad.
        do {
            _ = try JWTClaims.validate(jwt: jwt, expectedIntentID: intentID)
        } catch let error as ZennopayError {
            dispatchMain { completion(.failure(error)) }
            return
        } catch {
            // JWTClaims.validate only ever throws ZennopayError, but Swift's
            // type system requires us to handle the generic case.
            dispatchMain { completion(.failure(.malformedToken)) }
            return
        }

        let checkoutURL = buildCheckoutURL(intentID: intentID, jwt: jwt)

        // Forward-declared so the completion handler can release the retainer
        // for this session once it fires.
        var sessionRef: ASWebAuthenticationSession?

        let session = ASWebAuthenticationSession(
            url: checkoutURL,
            callbackURLScheme: returnScheme
        ) { callbackURL, error in
            defer {
                if let s = sessionRef {
                    ProviderRetainer.shared.release(for: s)
                }
            }
            if let error = error {
                if let asError = error as? ASWebAuthenticationSessionError,
                   asError.code == .canceledLogin {
                    dispatchMain { completion(.failure(.userCanceled)) }
                } else {
                    dispatchMain { completion(.failure(.networkError(error))) }
                }
                return
            }

            guard let callbackURL = callbackURL else {
                dispatchMain { completion(.failure(.returnURLMalformed)) }
                return
            }

            switch parseReturnURL(callbackURL) {
            case .success(let result):
                dispatchMain { completion(.success(result)) }
            case .failure(let parseError):
                dispatchMain { completion(.failure(parseError)) }
            }
        }
        sessionRef = session

        // Always start a clean web session for payments — we don't want a
        // stale auth cookie from a previous user to silently take over.
        session.prefersEphemeralWebBrowserSession = true

        let anchor = presentationContext ?? Self.defaultPresentationAnchor()
        let provider = PresentationContextProvider(anchor: anchor)

        // Hold a strong reference to the provider until the session completes;
        // ASWebAuthenticationSession only weakly retains its delegate.
        session.presentationContextProvider = provider
        ProviderRetainer.shared.retain(provider, for: session)

        guard session.start() else {
            ProviderRetainer.shared.release(for: session)
            dispatchMain { completion(.failure(.presentationAnchorMissing)) }
            return
        }
    }

    /// Async/throws variant for Swift Concurrency callers.
    @available(iOS 13.0, *)
    public static func openCheckout(
        intentID: String,
        jwt: String,
        returnScheme: String,
        presentationContext: ASPresentationAnchor? = nil
    ) async throws -> PaymentResult {
        try await withCheckedThrowingContinuation { continuation in
            openCheckout(
                intentID: intentID,
                jwt: jwt,
                returnScheme: returnScheme,
                presentationContext: presentationContext
            ) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: - Internal helpers (exposed for testing)

    /// Build the hosted checkout URL. The JWT is placed in the URL fragment
    /// (after `#`) so it is not transmitted to any HTTP server, never logged
    /// in proxy logs, and not visible in the browser's history sync.
    internal static func buildCheckoutURL(intentID: String, jwt: String) -> URL {
        let encodedIntent = intentID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? intentID
        let encodedJWT = jwt.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? jwt
        let urlString = "https://checkout.zennopay.com/flow/\(encodedIntent)/scan#token=\(encodedJWT)"
        // Force-unwrap is safe because we build a well-formed URL from
        // percent-encoded components; if it ever fails it's a programmer error.
        guard let url = URL(string: urlString) else {
            preconditionFailure("Zennopay: failed to build checkout URL from intent=\(intentID)")
        }
        return url
    }

    /// Parse the redirect URL coming back from the checkout web into a
    /// `PaymentResult`. Exposed `internal` so tests can drive it directly
    /// without spinning up `ASWebAuthenticationSession`.
    internal static func parseReturnURL(_ url: URL) -> Result<PaymentResult, ZennopayError> {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.returnURLMalformed)
        }

        let items = components.queryItems ?? []
        let intentID = items.first(where: { $0.name == "intent_id" })?.value
        let statusRaw = items.first(where: { $0.name == "status" })?.value

        guard let intentID = intentID, !intentID.isEmpty,
              let statusRaw = statusRaw, !statusRaw.isEmpty else {
            return .failure(.returnURLMalformed)
        }

        guard let status = PaymentStatus(rawValue: statusRaw) else {
            return .failure(.returnURLMalformed)
        }

        return .success(PaymentResult(intentID: intentID, status: status))
    }

    // MARK: - Private helpers

    private static func dispatchMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private static func defaultPresentationAnchor() -> ASPresentationAnchor {
        #if os(iOS)
        // Best-effort: find the first foreground active window scene's key window.
        // If the host needs a different window (e.g. multi-scene apps), they should
        // pass `presentationContext` explicitly.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        if let window = scenes.flatMap({ $0.windows }).first(where: { $0.isKeyWindow }) {
            return window
        }
        if let anyWindow = scenes.flatMap({ $0.windows }).first {
            return anyWindow
        }
        return ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

private final class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return anchor
    }
}

/// `ASWebAuthenticationSession` only weakly retains its presentation context
/// provider. We keep a strong reference here keyed by the session pointer
/// and drop it as soon as the session's completion handler fires.
private final class ProviderRetainer {
    static let shared = ProviderRetainer()
    private var providers: [ObjectIdentifier: PresentationContextProvider] = [:]
    private let lock = NSLock()

    func retain(_ provider: PresentationContextProvider, for session: ASWebAuthenticationSession) {
        lock.lock(); defer { lock.unlock() }
        providers[ObjectIdentifier(session)] = provider
    }

    func release(for session: ASWebAuthenticationSession) {
        lock.lock(); defer { lock.unlock() }
        providers.removeValue(forKey: ObjectIdentifier(session))
    }
}

