import Foundation
import CoreGraphics

/// Cross-platform (no UIKit / SwiftUI) currency + limit + radius helpers so the
/// pure logic is unit-testable on the macOS SwiftPM host. The UI layer formats
/// on top of these; the backend remains authoritative for money movement.

/// Clamp a corner radius into the DESIGN.md-legal range. Rectangular surfaces
/// are capped at 12px (no bubble-radius slop); negatives are floored at 0. This
/// is the single guardrail applied both in `ZennopayAppearance` and when a
/// partner-supplied appearance is resolved into a `ZTheme`.
enum RadiusGuard {
    static let maxRectRadius: CGFloat = 12
    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), maxRectRadius)
    }
}

/// Symbol / label / flag / formatting for the numeric ISO-4217 codes the
/// backend returns (`704` VND, `764` THB, `840` USD). All numeric display must
/// be rendered `.monospacedDigit()` at the view layer (DESIGN.md tabular-nums).
///
/// LOCAL currency is always the PRIMARY amount in the sheet (partner-approved
/// reference designs); USD is the secondary chip. Grouping is fixed to Western
/// thousands (a device-locale formatter would render VND in lakhs on an
/// Indian-region device).
enum CurrencyDisplay {

    /// Currency symbol for a numeric ISO-4217 code.
    static func symbol(forNumeric code: String?) -> String {
        switch code {
        case "764": return "฿"   // THB
        case "704": return "₫"   // VND
        case "840": return "$"   // USD
        default:    return ""
        }
    }

    /// Short alpha label for a numeric ISO-4217 code.
    static func label(forNumeric code: String?) -> String {
        switch code {
        case "764": return "THB"
        case "704": return "VND"
        case "840": return "USD"
        default:    return code ?? ""
        }
    }

    /// Flag emoji for a numeric ISO-4217 code (used on the merchant avatar and
    /// the secondary-amount chip).
    static func flag(forNumeric code: String?) -> String {
        switch code {
        case "764": return "🇹🇭"
        case "704": return "🇻🇳"
        case "840": return "🇺🇸"
        default:    return "🏳️"
        }
    }

    /// Whether a numeric ISO-4217 code uses minor units in display. VND (704)
    /// has no minor unit in practice; THB (764) uses satang (2 places).
    static func fractionDigits(forNumeric code: String?) -> Int {
        code == "704" ? 0 : 2
    }

    /// Shared formatter core: Western thousands grouping, fixed fraction digits.
    static func groupedNumber(_ value: Double, fractionDigits digits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.\(digits)f", value)
    }

    /// Render a minor-unit amount with the currency symbol prefixed, e.g.
    /// `฿120.00` / `₫3,500,000`. The backend value is authoritative; VND is
    /// shown without a fractional part, THB with two places.
    static func formatMinor(_ minorUnits: Int, numeric code: String?) -> String {
        let digits = fractionDigits(forNumeric: code)
        return symbol(forNumeric: code) + groupedNumber(Double(minorUnits) / 100, fractionDigits: digits)
    }

    /// Render a minor-unit amount with the alpha label suffixed and no symbol,
    /// e.g. `3,500,000 VND` — the receipt-card hero format.
    static func formatMinorWithLabel(_ minorUnits: Int, numeric code: String?) -> String {
        let digits = fractionDigits(forNumeric: code)
        return groupedNumber(Double(minorUnits) / 100, fractionDigits: digits)
            + " " + label(forNumeric: code)
    }

    /// Render a USD cent amount as `$1,140.00` (grouped, always 2 places).
    static func formatUSDCents(_ cents: Int) -> String {
        "$" + groupedNumber(Double(cents) / 100, fractionDigits: 2)
    }

    /// The implied exchange-rate line for the detail screens, e.g.
    /// `1 USD = 25,000.00 VND`. Nil when either side is zero/absent.
    static func exchangeRateLine(usdCents: Int, localMinorUnits: Int?, localCurrency: String?) -> String? {
        guard usdCents > 0, let minor = localMinorUnits, minor > 0 else { return nil }
        let rate = (Double(minor) / 100) / (Double(usdCents) / 100)
        return "1 USD = \(groupedNumber(rate, fractionDigits: 2)) \(label(forNumeric: localCurrency))"
    }
}

/// Backend-enforced VND disbursement caps. Only the
/// per-transaction cap is a client-side pre-check; the daily (10,000,000) and
/// monthly (25,000,000) caps require server state and surface at confirm.
enum DisbursementLimit {
    /// Per-transaction VND cap, in the backend's minor-unit convention.
    static let vndPerTransactionMinorUnits = 500_000_000
    /// VND numeric ISO-4217 code.
    static let vndNumeric = "704"

    /// Client pre-check: is the (dynamic or entered) amount above the
    /// per-transaction VND cap? Only applies to VND (704).
    static func exceedsVNDPerTransaction(minorUnits: Int, currencyNumeric: String?) -> Bool {
        currencyNumeric == vndNumeric && minorUnits > vndPerTransactionMinorUnits
    }
}

/// Pure input policy for the static-QR amount keypad. Keeps every rule
/// unit-testable off the UI: leading zeros are silently ignored, and any
/// keypress that would push the amount past the hard digit ceiling or the
/// per-transaction VND cap is REFUSED (the UI answers a refusal with a gentle
/// shake + the limit copy — the hero can never overflow).
enum KeypadInputPolicy {

    /// Hard ceiling on entered major-unit digits regardless of currency
    /// (999,999,999 major units) — keeps the hero legible at its
    /// minimum-scale floor even for non-VND corridors with no client cap.
    static let maxDigits = 9

    /// Outcome of applying one keypad key to the current digit string.
    enum Outcome: Equatable {
        /// The digits changed (or an ignorable no-op like a leading zero).
        case accepted(String)
        /// The key would exceed a cap; digits unchanged. `hint` is the copy
        /// to surface (nil = generic length cap).
        case refused(hint: Hint)
    }

    /// Why input was refused.
    enum Hint: Equatable {
        /// Above the ₫5,000,000 per-payment cap (VND only).
        case vndPerTransactionLimit
        /// Above the general digit ceiling.
        case maxLength
    }

    /// Apply a single digit ("0"–"9").
    static func appendingDigit(
        _ digits: String, _ d: String, currencyNumeric: String?
    ) -> Outcome {
        if digits.isEmpty && d == "0" { return .accepted(digits) }  // silent no-op
        return vet(candidate: digits + d, currencyNumeric: currencyNumeric)
    }

    /// Apply the "000" key.
    static func appendingTripleZero(
        _ digits: String, currencyNumeric: String?
    ) -> Outcome {
        guard !digits.isEmpty else { return .accepted(digits) }  // silent no-op
        return vet(candidate: digits + "000", currencyNumeric: currencyNumeric)
    }

    private static func vet(candidate: String, currencyNumeric: String?) -> Outcome {
        guard candidate.count <= maxDigits, let major = Int(candidate) else {
            return .refused(hint: .maxLength)
        }
        // Major units → the backend's minor-unit convention (×100).
        let minorUnits = major * 100
        if DisbursementLimit.exceedsVNDPerTransaction(
            minorUnits: minorUnits, currencyNumeric: currencyNumeric
        ) {
            return .refused(hint: .vndPerTransactionLimit)
        }
        return .accepted(candidate)
    }
}
