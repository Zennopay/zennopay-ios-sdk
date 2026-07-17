import Foundation

/// Wire types for the SDK-facing REST surface. These are the request/response
/// bodies for `/scan`, `/confirm`, and `GET /:id`.
///
/// RECONCILED to the NOW-CANONICAL backend contract (`docs/sdk-rest-contract.md`
/// + the golden fixtures in `sdk-contract-fixtures/*.json`). The field names,
/// types, and optionality below decode those captured examples verbatim.
///
/// Notes carried from the reconciliation:
///  - `merchant.scheme` (was `network`): the EMVCo scheme, e.g. "promptpay",
///    "vietqr". Not a display label.
///  - `qr_kind` (was `amount_is_fixed`): "dynamic" | "static". A dynamic QR
///    embeds the amount; a static QR needs `local_amount_minor_units` from the
///    user at scan time.
///  - `quote.local_amount_minor_units` (was `local_amount_minor`).
///  - `quote.local_currency` is a NUMERIC ISO-4217 string, e.g. "704" (VND),
///    "764" (THB) — not an alpha code.
///  - `quote.expires_at` is epoch MILLISECONDS (Int), not an ISO-8601 string.
///  - The invented `fx_rate` field is gone: the backend does not return it.

// MARK: - Scan

/// Request body for `POST /v1/payment_intents/:id/scan`. We send the RAW QR
/// string; the backend authoritatively parses the EMVCo TLV (CRC-16 check,
/// merchant extraction). We never trust a local parse for money movement.
///
/// The backend's `ScanBody` accepts ONLY `qr_payload` and (optional)
/// `local_amount_minor_units` — there is no `corridor` field (the corridor is
/// taken from the session JWT's `zennopay:corridor` claim). The invented
/// `corridor` request field has been removed.
struct ScanRequest: Encodable {
    /// The raw, undecoded QR payload string exactly as scanned.
    let qr_payload: String
    /// User-entered local amount (minor units) for a STATIC QR. Required for
    /// static QRs; omit for dynamic QRs (the embedded amount is authoritative,
    /// and an override is rejected). Encoded only when present.
    let local_amount_minor_units: Int?
}

/// Response body for a successful `/scan`: validated merchant + FX quote.
struct ScanResponse: Decodable, Equatable {
    /// The intent this scan bound the quote to (echoes the URL `:id`).
    let intent_id: String
    /// Intent lifecycle status after scan (e.g. "created").
    let status: String
    let merchant: Merchant
    /// "dynamic" | "static".
    let qr_kind: String
    let quote: Quote

    struct Merchant: Decodable, Equatable {
        /// EMVCo scheme that validated the QR, e.g. "promptpay", "vietqr".
        let scheme: String?
        /// Display name of the beneficiary merchant. NULLABLE: a personal /
        /// bank-account VietQR (peer transfer) carries no merchant-name tag, so
        /// the backend returns null here. A non-optional decode would fail the
        /// whole scan response ("Something went wrong") on those QRs.
        let name: String?
        /// City / locality carried by the QR.
        let city: String?
        /// ISO-3166 alpha-2 country, e.g. "TH", "VN".
        let country: String?
        /// Merchant Category Code.
        let mcc: String?
    }

    struct Quote: Decodable, Equatable {
        /// Opaque quote identifier. Echoed back on `/confirm`.
        let quote_id: String
        /// Monotonic version; a newer quote supersedes an older one.
        let quote_version: Int
        /// USD amount that will be debited from the user's wallet, in cents.
        let amount_usd_cents: Int
        /// The local-currency amount, in minor units (satang / dong).
        let local_amount_minor_units: Int
        /// NUMERIC ISO-4217 code of the local currency, e.g. "704", "764".
        let local_currency: String
        /// Quote expiry as epoch MILLISECONDS.
        let expires_at: Int
    }
}

// MARK: - Confirm

/// Request body for `POST /:id/confirm`. Binds the confirm to the FX quote the
/// SDK displayed. Sent alongside the `Idempotency-Key` header.
///
/// `local_amount_minor_units` is deliberately NOT sent: it is rejected on a
/// dynamic QR, and the quote already pins the amount for static QRs.
struct ConfirmRequest: Encodable {
    let quote_id: String
    let quote_version: Int
}

/// Response body for `POST /:id/confirm` — the full payment-intent record with
/// the terminal `status` and `confirm_state`. `GET /:id` returns the same
/// snapshot shape, so both decode into `IntentSnapshot`.
typealias ConfirmResponse = IntentSnapshot

// MARK: - Status / intent snapshot

/// Response body for `POST /:id/confirm` and `GET /v1/payment_intents/:id`.
///
/// The GET/SDK projection may omit the richer confirm-only fields (the contract
/// documents a minimal `{ id, status, amount_usd_cents, corridor, created_at,
/// updated_at }` shape for the plain status read), so every field beyond that
/// core is decoded as OPTIONAL. The confirm fixture carries them all.
struct IntentSnapshot: Decodable, Equatable {
    let id: String
    let status: String
    let amount_usd_cents: Int
    let corridor: String?

    // Present on the confirm response (and richer status snapshots).
    let merchant: ConfirmMerchant?
    let qr_kind: String?
    let quote_id: String?
    let quote_version: Int?
    let quote_local_amount_minor_units: Int?
    let quote_local_currency: String?
    let quote_expires_at: Int?
    let confirm_state: String?
    let beneficiary: Beneficiary?
    let transaction_id: String?
    let created_at: String?
    let updated_at: String?

    /// The merchant block on the confirm/status record. Carries the numeric
    /// currency (`currency_numeric`) that `/scan`'s merchant block does not.
    struct ConfirmMerchant: Decodable, Equatable {
        let scheme: String?
        let name: String?
        let city: String?
        let country: String?
        let mcc: String?
        let currency_numeric: String?
    }

    /// The persisted payout beneficiary extracted from the QR. Structure is
    /// scheme-dependent; only the fields the SDK might surface are typed, the
    /// rest are ignored.
    struct Beneficiary: Decodable, Equatable {
        let scheme: String?
        let merchant_name: String?
        let merchant_city: String?
        let country: String?
        let currency_numeric: String?
        let mcc: String?
    }
}

// MARK: - Error envelope

/// The backend error envelope: `{ error: { code, message, request_id } }`
/// (see `backend/src/util/errors.ts`).
///
/// IMPORTANT — reconciliation finding: the wire `code` is a GENERIC
/// `ErrorCode` (`authentication_failed`, `conflict`, `validation_failed`, …).
/// The specific reasons named in the contract (`jwt.jti_replay`,
/// `confirm.quote_expired`, `confirm.quote_mismatch`, …) are the server-side
/// `internalReason` and are NOT serialized to the client — only `code`,
/// a generic `message`, and `request_id` cross the wire. The SDK therefore maps
/// on `(httpStatus, code, onConfirm)`; it cannot distinguish, say,
/// `quote_expired` from `quote_mismatch` (both are HTTP 409 / `conflict`).
struct ErrorEnvelope: Decodable {
    let error: Payload
    struct Payload: Decodable {
        let code: String?
        let message: String?
        let request_id: String?
    }
}
