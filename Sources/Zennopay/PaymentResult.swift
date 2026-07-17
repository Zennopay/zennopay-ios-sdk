import Foundation

/// The intent lifecycle statuses the backend reports on `GET /v1/payment_intents/:id`.
///
/// Mirrors `backend/src/services/payment_intent_service.ts` `IntentStatus`.
/// `created`/`authorized` are non-terminal; the rest are terminal. The SDK
/// polls until a terminal state, then collapses it into a `PaymentResult`.
public enum IntentStatus: String, Equatable, Sendable {
    case created
    case authorized
    case captured
    case failed
    case refunded
    case reversed
    case expired

    /// A state from which the intent will not move on its own — polling stops.
    public var isTerminal: Bool {
        switch self {
        case .captured, .failed, .refunded, .reversed, .expired:
            return true
        case .created, .authorized:
            return false
        }
    }
}

/// The outcome delivered to the host via the `onResult` callback.
///
/// This is the public, platform-neutral shape (parallel to the Android SDK's
/// `PaymentResult`). It collapses the backend intent status into four cases
/// the host renders its own UI for.
public enum PaymentResult: Equatable, Sendable {
    /// The wallet was debited and the payout captured. `intentID` echoes the
    /// confirmed intent for the host's records.
    case completed(intentID: String)

    /// The payment reached a terminal non-success state, or the flow failed in
    /// a way the user could not recover from in-sheet.
    case failed(intentID: String, error: ZennopayError)

    /// The payment was confirmed but had not reached a terminal state when the
    /// sheet closed — either the user chose to leave while it was processing
    /// ("Done" on the processing screen) or status polling timed out. The
    /// payment may still settle; the host should reconcile via webhook /
    /// `GET /v1/payment_intents/:id`. If it does not complete, the money is
    /// refunded to the wallet automatically.
    case pending(intentID: String)

    /// The user dismissed the flow before a terminal outcome. No money moved.
    case canceled(intentID: String)

    /// Convenience: the intent this result concerns.
    public var intentID: String {
        switch self {
        case let .completed(id), let .canceled(id), let .pending(id):
            return id
        case let .failed(id, _):
            return id
        }
    }

    /// Collapse a terminal `IntentStatus` into a result for the given intent.
    /// Non-terminal statuses arriving here mean the poll budget lapsed without
    /// resolution — that is a PENDING outcome, never a hard failure (the
    /// backend auto-refunds an unsettled debit).
    static func from(status: IntentStatus, intentID: String) -> PaymentResult {
        switch status {
        case .captured:
            return .completed(intentID: intentID)
        case .failed:
            return .failed(intentID: intentID, error: .paymentFailed)
        case .expired:
            return .failed(intentID: intentID, error: .quoteExpired)
        case .refunded, .reversed:
            // The forward flow doesn't produce these, but a relaunch-recovery
            // GET might observe a post-hoc refund. Treat as completed-then-
            // refunded from the pay-flow's perspective: the debit did happen.
            return .completed(intentID: intentID)
        case .created, .authorized:
            return .pending(intentID: intentID)
        }
    }
}
