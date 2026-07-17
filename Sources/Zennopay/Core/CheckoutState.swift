import Foundation

/// The platform-neutral checkout state machine (design doc T-STATE-MACHINE /
/// D6=A): scan → quote → confirm → result, with expiry / cancel / pending /
/// error transitions. The SwiftUI/UIKit layer renders one screen per state and
/// forwards user actions back into the machine.
///
/// States are intentionally coarse and map 1:1 to a screen:
enum CheckoutState: Equatable {
    /// Scanning for a QR code (camera live, or paste-fallback shown).
    case scanning
    /// A STATIC QR (no embedded amount) was captured; the user is entering the
    /// local-currency amount on the keypad before we `/scan` with it.
    case amountEntry(rawPayload: String)
    /// A raw QR string was captured and is being submitted to `/scan`.
    case validatingScan
    /// `/scan` returned a merchant + quote; the amount screen is shown.
    case quoted(Quote)
    /// The user slid to confirm; `/confirm` is in flight.
    case confirming
    /// `/confirm` returned; polling `GET /:id` for a terminal state.
    case awaitingResult
    /// Terminal — the flow is done; `PaymentResult` has been (or is about to be)
    /// delivered to the host.
    case finished(PaymentResult)

    /// The quote + merchant display data carried into the amount screen.
    struct Quote: Equatable {
        /// Nil for a personal / bank-account VietQR (no merchant-name tag) —
        /// the UI applies a corridor-aware fallback ("Vietnam Merchant").
        let merchantName: String?
        let merchantCity: String?
        /// EMVCo scheme, e.g. "promptpay" / "vietqr" (was `network`).
        let scheme: String?
        let amountUSDCents: Int
        /// Local amount in minor units (was `localAmountMinor`).
        let localAmountMinorUnits: Int?
        /// Numeric ISO-4217 currency, e.g. "704" / "764".
        let localCurrency: String?
        /// Whether the QR fixes the amount ("dynamic") vs the user enters it
        /// ("static"). Derived from `qr_kind`.
        let amountIsFixed: Bool
        let expiresAt: Date?

        /// Quote binding, threaded into `/confirm` (`quote_id` + `quote_version`).
        let quoteID: String
        let quoteVersion: Int

        init(from response: ScanResponse, defaultTTL: TimeInterval, now: Date = Date()) {
            // A personal / bank-account VietQR carries no merchant-name tag;
            // keep nil (or empty) so the UI can apply its corridor-aware
            // fallback rather than baking a neutral label in here.
            merchantName = (response.merchant.name?.isEmpty == false) ? response.merchant.name : nil
            merchantCity = response.merchant.city
            scheme = response.merchant.scheme
            amountUSDCents = response.quote.amount_usd_cents
            localAmountMinorUnits = response.quote.local_amount_minor_units
            localCurrency = response.quote.local_currency
            amountIsFixed = response.qr_kind == "dynamic"
            quoteID = response.quote.quote_id
            quoteVersion = response.quote.quote_version
            // `expires_at` is epoch MILLISECONDS. A 0/absent value falls back to
            // a default TTL from now.
            if response.quote.expires_at > 0 {
                expiresAt = Date(timeIntervalSince1970: Double(response.quote.expires_at) / 1000)
            } else {
                expiresAt = now.addingTimeInterval(defaultTTL)
            }
        }

        /// Whether the quote's validity window has passed.
        func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return now >= expiresAt
        }
    }
}

/// Legal transitions, expressed as a pure function so the contract is testable
/// without a live client. Returns the next state, or `nil` if the transition is
/// illegal (a programmer error or an out-of-order event to ignore).
enum CheckoutTransition {

    /// Events that can drive the machine.
    enum Event: Equatable {
        case qrCaptured           // raw string in hand → validate
        case staticQRCaptured(rawPayload: String)  // static QR → keypad first
        case scanValidated(CheckoutState.Quote)
        case scanRejected         // /scan failed
        case userConfirmed        // slid to pay → /confirm
        case confirmAccepted      // /confirm returned → poll
        case terminal(PaymentResult)
        case cancel
        case reScan               // quote expired or user chose to re-scan
    }

    static func next(from state: CheckoutState, on event: Event) -> CheckoutState? {
        switch (state, event) {
        case (.scanning, .qrCaptured), (.amountEntry, .qrCaptured):
            return .validatingScan
        case (.scanning, .staticQRCaptured(let raw)):
            return .amountEntry(rawPayload: raw)
        case (.validatingScan, .scanValidated(let q)):
            return .quoted(q)
        case (.validatingScan, .scanRejected):
            return .scanning
        case (.quoted, .userConfirmed):
            return .confirming
        case (.quoted, .reScan), (.scanning, .reScan), (.amountEntry, .reScan):
            return .scanning
        case (.confirming, .confirmAccepted):
            return .awaitingResult
        // Terminal can be reached from confirm/await (success/fail) or any
        // state via an error.
        case (_, .terminal(let result)):
            return .finished(result)
        // Cancel is legal from any non-terminal state.
        case (.finished, .cancel):
            return nil
        case (_, .cancel):
            return .finished(.canceled(intentID: ""))  // intentID filled by controller
        default:
            return nil
        }
    }
}
