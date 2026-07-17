import Foundation

/// Errors surfaced by the Zennopay native SDK.
///
/// This is the client half of the shared error taxonomy (design doc
/// T-STATE-MACHINE / eng-review-4). Every failure the host can observe maps to
/// exactly one case here. `ZennopayError.from(httpStatus:code:)` maps the
/// backend's `{ error: { code, message } }` envelope (see
/// `backend/src/util/errors.ts`) onto these cases so the SDK reacts
/// consistently regardless of which endpoint failed.
public enum ZennopayError: Error, Equatable {

    // MARK: Input / token errors (fail before any network call)

    /// The session JWT supplied to `presentCheckout` was empty or whitespace.
    case invalidJWT

    /// The JWT is not a syntactically valid token (wrong segment count,
    /// undecodable base64url, payload is not a JSON object).
    case malformedToken

    /// The JWT's `zennopay:intent_id` claim does not match the `intentID`
    /// argument. Fail fast: the host paired a token minted for one intent with
    /// a different intent.
    case intentMismatch

    /// The JWT's `exp` claim is in the past (beyond clock-skew tolerance) at
    /// call time. Recoverable via the host `refreshSession` hook.
    case jwtExpired

    /// The JWT is missing a required claim (`zennopay:intent_id`, `exp`,
    /// `iss`, or `aud`).
    case jwtMissingClaim

    // MARK: Auth / lifecycle errors (from the backend)

    /// The backend rejected the bearer token (401). After one automatic
    /// `refreshSession` attempt fails or is unavailable, this is surfaced.
    case sessionExpired

    /// The single-use confirm jti was already consumed — a second `/confirm`
    /// with the same token. Backend internal reason `jwt.jti_replay`. The SDK
    /// recovers by polling status rather than re-confirming.
    case confirmReplay

    // MARK: Scan / quote errors

    /// The scanned QR could not be validated by the backend (bad CRC, unknown
    /// merchant, unsupported corridor). Backend `validation_failed` on `/scan`.
    case invalidQRCode

    /// The FX quote returned by `/scan` (or its refresh) has expired and could
    /// not be refreshed. The user must re-scan or re-enter the amount.
    case quoteExpired

    // MARK: Confirm / money-movement errors

    /// The wallet debit or provider payout failed (terminal `failed` status,
    /// or a 4xx/5xx on confirm that isn't auth/replay). Retryable via the
    /// result screen.
    case paymentFailed

    // MARK: Flow control

    /// The user dismissed the flow (back-swipe, cancel button, or scanner
    /// close) before a terminal outcome.
    case userCanceled

    /// The camera permission was denied and the user did not use the
    /// paste-QR fallback. Not fatal on its own — surfaced only if the flow is
    /// abandoned from the denial screen.
    case cameraPermissionDenied

    /// Status polling exceeded `statusPollTimeout` without reaching a terminal
    /// state. The payment may still settle; the host should reconcile via
    /// webhook / `GET /:id`.
    case timedOut

    /// No presentation context (host view controller) was available.
    case presentationContextMissing

    // MARK: Transport / catch-all

    /// A transport-level failure (no connectivity, TLS, timeout) that isn't one
    /// of the semantic cases above.
    case networkError(underlying: String)

    /// The backend returned an HTTP error that doesn't map to a more specific
    /// case. Carries the HTTP status and the backend `code` for triage.
    case serverError(status: Int, code: String)

    // MARK: - Backend error-envelope mapping

    /// Map a backend HTTP failure onto the taxonomy. `code` is the
    /// `error.code` field from the backend envelope (may be a generic
    /// `ErrorCode` like `authentication_failed`, or a synthesized `http_<n>`
    /// when the body was unparseable).
    ///
    /// - Parameters:
    ///   - httpStatus: the HTTP status code.
    ///   - code: the backend `error.code`, if any.
    ///   - onConfirm: whether this failure happened on the `/confirm` call,
    ///     which changes how a 401/409 is interpreted (replay vs generic).
    static func from(httpStatus: Int, code: String?, onConfirm: Bool = false) -> ZennopayError {
        // Reconciliation note: the backend wire body exposes only a GENERIC
        // `code` (`authentication_failed` / `conflict` / `validation_failed` /
        // …). The specific reasons from the contract — `jwt.jti_replay`,
        // `jwt.intent_id_mismatch_with_path`, `confirm.quote_expired`,
        // `confirm.quote_mismatch`, `confirm.quote_superseded`,
        // `confirm.not_scanned`, `confirm.dynamic_amount_override`,
        // `scan.validation_failed` — are the server-side `internalReason` and
        // do NOT cross the wire. So we map on (httpStatus, generic code,
        // onConfirm) and cannot distinguish, e.g., a quote_expired from a
        // quote_mismatch (both are 409 / `conflict`).
        switch httpStatus {
        case 401:
            // `authentication_failed`. On /confirm a 401 covers `jwt.jti_replay`
            // (a second confirm) and `jwt.intent_invalid_state` — both mean the
            // money call already ran (or the intent is terminal), so recover by
            // polling status rather than treating it as a fatal auth error.
            // On /scan and GET, a 401 is a stale/invalid session → the caller
            // (RESTClient) has already tried refreshSession before we get here,
            // so surface `.sessionExpired`.
            return onConfirm ? .confirmReplay : .sessionExpired
        case 403:
            // HMAC-path `authorization_failed` (not on the SDK JWT path).
            return .serverError(status: 403, code: code ?? "authorization_failed")
        case 409:
            // `conflict`. On /confirm this is a quote problem
            // (`confirm.quote_expired` / `quote_mismatch` / `quote_superseded` /
            // `not_scanned`) or the single-flight losing a CAS. Treat every
            // confirm 409 as "recover the real state" — quoteExpired is the
            // closest user-facing signal (re-scan / re-quote). On /scan or GET a
            // 409 is an already-terminal / confirm-locked intent.
            return onConfirm ? .quoteExpired : .serverError(status: 409, code: code ?? "conflict")
        case 400, 422:
            // `validation_failed`. On /scan this is a bad QR (`qr.*`). On
            // /confirm it is a bad body or `confirm.dynamic_amount_override`.
            return onConfirm ? .paymentFailed : .invalidQRCode
        case 404:
            return .serverError(status: 404, code: code ?? "not_found")
        case 429:
            return .serverError(status: 429, code: code ?? "rate_limited")
        default:
            return .serverError(status: httpStatus, code: code ?? "http_\(httpStatus)")
        }
    }
}
