import Foundation

/// The status rollup returned by `GET /v1/payment_intents/:id/receipt`.
///
/// The receipt endpoint collapses the richer intent lifecycle
/// (`created`/`authorized`/`captured`/`failed`/`refunded`/`reversed`/`expired`)
/// into the four states a past-payment receipt needs to render:
///  - `pending`   — not yet terminal; the SDK polls until it resolves.
///  - `captured`  — settled successfully; show the success receipt.
///  - `failed`    — terminal failure; show the failure screen.
///  - `refunded`  — captured then refunded; show the receipt with refund copy.
enum ReceiptStatus: String, Equatable, Sendable {
    case pending
    case captured
    case failed
    case refunded

    /// A state the receipt will not move out of on its own — polling stops.
    var isTerminal: Bool { self != .pending }
}

/// Response body for `GET /v1/payment_intents/:id/receipt` — the authoritative
/// receipt for a past payment, authenticated by a partner-minted RS256 receipt
/// token (`aud = zennopay-receipt`).
///
/// The decode is deliberately tolerant: only `intent_id`/`status` are treated as
/// load-bearing; every display field is optional and the soft numeric fields
/// (`exchange_rate`) accept either a JSON number or a numeric string so a wire
/// shape drift can never fail the whole decode (the SDK still renders what it
/// has). The backend remains authoritative.
struct ReceiptDTO: Equatable {
    let intent_id: String
    /// "pending" | "captured" | "failed" | "refunded".
    let status: String
    let merchant: ReceiptMerchant?
    let amount_usd_cents: Int
    let local_amount_minor_units: Int?
    /// Numeric ISO-4217 (e.g. "704") or alpha (e.g. "VND") — normalized at the
    /// display layer via `CurrencyDisplay.numericCode(from:)`.
    let local_currency: String?
    let exchange_rate: Double?
    let fees: Fees?
    let corridor: String?
    /// Provider transaction reference — shown as the receipt's "Transaction ID".
    let transaction_ref: String?
    let created_at: String?
    let updated_at: String?

    /// The beneficiary merchant. `account_no` is already masked to the last 4
    /// by the backend (never a full PAN), so the SDK renders it verbatim.
    struct ReceiptMerchant: Decodable, Equatable {
        let name: String?
        let account_no: String?
        let bank_no: String?
        let country: String?
    }

    /// The Zennopay margin taken on the corridor, in USD cents.
    struct Fees: Decodable, Equatable {
        let margin_usd_cents: Int?
    }

    /// The parsed status, or nil for an unknown wire value.
    var receiptStatus: ReceiptStatus? { ReceiptStatus(rawValue: status) }
}

extension ReceiptDTO: Decodable {
    private enum CodingKeys: String, CodingKey {
        case intent_id, status, merchant, amount_usd_cents
        case local_amount_minor_units, local_currency, exchange_rate
        case fees, corridor, transaction_ref, created_at, updated_at
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intent_id = try c.decode(String.self, forKey: .intent_id)
        status = try c.decode(String.self, forKey: .status)
        merchant = try c.decodeIfPresent(ReceiptMerchant.self, forKey: .merchant)
        amount_usd_cents = (try? c.decodeIfPresent(Int.self, forKey: .amount_usd_cents)) ?? 0
        local_amount_minor_units = try? c.decodeIfPresent(Int.self, forKey: .local_amount_minor_units)
        local_currency = try? c.decodeIfPresent(String.self, forKey: .local_currency)
        fees = try? c.decodeIfPresent(Fees.self, forKey: .fees)
        corridor = try? c.decodeIfPresent(String.self, forKey: .corridor)
        transaction_ref = try? c.decodeIfPresent(String.self, forKey: .transaction_ref)
        created_at = try? c.decodeIfPresent(String.self, forKey: .created_at)
        updated_at = try? c.decodeIfPresent(String.self, forKey: .updated_at)

        // `exchange_rate` may arrive as a number or a numeric string. Accept
        // both; nil out anything else rather than failing the receipt decode.
        if let d = try? c.decodeIfPresent(Double.self, forKey: .exchange_rate) {
            exchange_rate = d
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .exchange_rate) {
            exchange_rate = Double(s)
        } else {
            exchange_rate = nil
        }
    }
}
