import Foundation

/// On-device QR payload handling — the *display-only* half of the scan.
///
/// CRITICAL (design doc D4=A / T-QR-BACKEND-PARSE): the client MUST NOT trust
/// any locally-parsed field for money movement. The backend authoritatively
/// re-parses the raw EMVCo TLV (CRC-16 check, merchant extraction, static-vs-
/// dynamic amount rules). This type does only two safe things:
///   1. Sanity-guards a captured string before we bother the network (reject
///      empty / absurdly long / clearly-non-EMVCo blobs).
///   2. Optionally sniffs the corridor (PromptPay vs VietQR) as a *hint* to
///      send alongside the raw payload — never as an authority.
enum QRPayload {

    /// The raw string is passed to the backend verbatim; this only screens out
    /// obvious garbage so we don't spend a round-trip (and a jti-free scan)
    /// on it. EMVCo QR strings are short; 4096 is a generous ceiling.
    static let maxLength = 4096

    /// A captured string is *plausibly* an EMVCo merchant-presented QR.
    /// EMVCo payloads begin with tag `00` (Payload Format Indicator) length
    /// `02` value `01` → the literal prefix `"000201"`. We check that prefix
    /// as a cheap, non-authoritative screen.
    static func looksLikeEMVCo(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return false }
        return trimmed.hasPrefix("000201")
    }

    /// Validate a captured/pasted string before submitting to `/scan`.
    /// - Returns: the trimmed raw payload to send.
    /// - Throws: `.invalidQRCode` if it can't be a merchant QR.
    static func validate(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ZennopayError.invalidQRCode }
        guard trimmed.count <= maxLength else { throw ZennopayError.invalidQRCode }
        // We do NOT reject a non-`000201` prefix outright when it came from the
        // paste field (some merchants print URL-wrapped QRs); we only require
        // that it's non-trivial. The backend is the authority. But we do reject
        // strings with no printable content.
        guard trimmed.rangeOfCharacter(from: CharacterSet.alphanumerics) != nil else {
            throw ZennopayError.invalidQRCode
        }
        return trimmed
    }

    /// Corridor hint from the raw payload. EMVCo merchant account templates:
    /// PromptPay uses the `A000000677010111` AID (tag 29/30); VietQR uses
    /// `A000000727` (NAPAS). This is a heuristic *hint* only.
    /// - Returns: `"th_promptpay"`, `"vn_vietqr"`, or nil when undetermined.
    static func corridorHint(_ raw: String) -> String? {
        if raw.contains("A000000677") { return "th_promptpay" }
        if raw.contains("A000000727") { return "vn_vietqr" }
        return nil
    }

    // MARK: - Display-only peek (D4=A: NEVER trusted for money movement)

    /// Display-only facts peeked from the raw EMVCo TLV. Used to (a) route a
    /// STATIC QR to the amount keypad before the network scan, and (b) surface
    /// the beneficiary bank + masked account on the review/receipt screens.
    /// The backend re-parses the raw payload authoritatively on `/scan`.
    struct Peek: Equatable {
        /// Tag 54 (transaction amount) absent → static QR: the user enters the
        /// amount before we `/scan`.
        let isStatic: Bool
        /// VietQR (NAPAS tag 38): the 6-digit acquirer BIN, e.g. "970436".
        let bankBIN: String?
        /// VietQR: the beneficiary account/card number.
        let accountNumber: String?
        /// Display name for `bankBIN` when known (small client-side map).
        var bankName: String? {
            guard let bankBIN else { return nil }
            return QRPayload.vietnamBankNames[bankBIN]
        }
        /// The account with all but the leading 5 / trailing 4 digits elided,
        /// e.g. `10230…0000`. Nil when no account was peeked.
        var accountMasked: String? {
            guard let accountNumber, accountNumber.count > 9 else { return accountNumber }
            return accountNumber.prefix(5) + "…" + accountNumber.suffix(4)
        }
    }

    /// Well-known Vietnamese acquirer BINs (NAPAS). Display-only.
    static let vietnamBankNames: [String: String] = [
        "970436": "VIETCOMBANK",
        "970415": "VIETINBANK",
        "970418": "BIDV",
        "970405": "AGRIBANK",
        "970407": "TECHCOMBANK",
        "970422": "MB BANK",
        "970416": "ACB",
        "970432": "VPBANK",
        "970423": "TPBANK",
        "970403": "SACOMBANK",
    ]

    /// Peek display-only facts from a raw EMVCo payload. Returns a best-effort
    /// result — a malformed TLV yields `Peek(isStatic: false, ...)` so the flow
    /// falls through to the authoritative backend scan.
    static func peek(_ raw: String) -> Peek {
        guard let fields = parseTLV(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return Peek(isStatic: false, bankBIN: nil, accountNumber: nil)
        }
        let isStatic = fields["54"] == nil
        // NAPAS VietQR merchant account template lives in tag 38:
        //   00 = AID (A000000727), 01 = nested { 00 = acquirer BIN, 01 = account }.
        var bin: String?
        var account: String?
        if let napas = fields["38"], napas.contains("A000000727"),
           let sub = parseTLV(napas),
           let beneficiary = sub["01"], let inner = parseTLV(beneficiary) {
            bin = inner["00"]
            account = inner["01"]
        }
        return Peek(isStatic: isStatic, bankBIN: bin, accountNumber: account)
    }

    /// Minimal EMVCo TLV parse: repeated `tag(2) length(2) value(length)`.
    /// Returns nil when the string doesn't cleanly tokenize.
    static func parseTLV(_ s: String) -> [String: String]? {
        var fields: [String: String] = [:]
        var idx = s.startIndex
        while idx < s.endIndex {
            guard let tagEnd = s.index(idx, offsetBy: 2, limitedBy: s.endIndex),
                  let lenEnd = s.index(tagEnd, offsetBy: 2, limitedBy: s.endIndex),
                  let length = Int(s[tagEnd..<lenEnd]),
                  let valEnd = s.index(lenEnd, offsetBy: length, limitedBy: s.endIndex)
            else { return nil }
            fields[String(s[idx..<tagEnd])] = String(s[lenEnd..<valEnd])
            idx = valEnd
        }
        return fields.isEmpty ? nil : fields
    }
}
