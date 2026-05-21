import Foundation

/// Lightweight, on-device inspection of a JWT's payload claims.
///
/// We **do not** verify the JWT signature here — the Zennopay backend (and
/// the checkout web) are the authority on signature/issuer validity. The
/// SDK's job is purely to fail fast on the client when the host hands us a
/// token that is obviously bound to the wrong intent or already expired,
/// so we never open a system browser with a doomed request and never leak
/// an intent ID into a URL we know won't succeed.
///
/// Threat we're closing: a host app that caches or reuses a JWT minted for
/// one intent and accidentally (or maliciously) calls `openCheckout` with a
/// different `intentID`. Without this check the browser opens, the user
/// sees a real checkout URL, the backend later rejects the token, and the
/// user is left staring at an error page — and we've leaked one intent ID
/// in the URL to a partner who wasn't supposed to see it.
///
/// Implementation: pure Foundation, zero networking. We only parse the
/// middle (payload) segment as base64url JSON.
internal enum JWTClaims {

    /// Required claims for a Zennopay-issued JWT.
    struct Decoded: Equatable {
        let intentID: String
        let expiresAt: Date
        let issuer: String
    }

    /// Decode the payload segment of a JWT and validate the claims we care
    /// about against the supplied `intentID` and current clock.
    ///
    /// - Parameters:
    ///   - jwt: The raw `header.payload.signature` string.
    ///   - expectedIntentID: The intent ID the host wants to check out. Must
    ///     match `zennopay:intent_id` in the JWT payload exactly.
    ///   - now: Current time. Parameterized so tests can inject a fixed clock.
    ///   - clockSkewTolerance: How far past `exp` we still accept. Defaults
    ///     to 30s, matching the spec's allowance for client/server drift.
    /// - Throws: A `ZennopayError` describing the first failure encountered.
    /// - Returns: The decoded claim bag, if everything checks out.
    static func validate(
        jwt: String,
        expectedIntentID: String,
        now: Date = Date(),
        clockSkewTolerance: TimeInterval = 30
    ) throws -> Decoded {
        // Split into header / payload / signature. We never touch header or
        // signature on-device.
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else {
            throw ZennopayError.malformedToken
        }

        let payloadSegment = String(segments[1])
        guard !payloadSegment.isEmpty,
              let payloadData = base64URLDecode(payloadSegment) else {
            throw ZennopayError.malformedToken
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: payloadData, options: [])
        } catch {
            throw ZennopayError.malformedToken
        }

        guard let claims = json as? [String: Any] else {
            throw ZennopayError.malformedToken
        }

        // zennopay:intent_id is a custom claim. The colon is legal in JSON
        // keys; we use the namespaced form to avoid collisions with hosts
        // who may have their own `intent_id` claim for unrelated purposes.
        guard let claimIntentID = claims["zennopay:intent_id"] as? String,
              !claimIntentID.isEmpty else {
            throw ZennopayError.jwtMissingClaim
        }

        // Intent mismatch is checked before exp so a stale token reused for
        // a brand-new intent surfaces the more actionable error.
        guard claimIntentID == expectedIntentID else {
            throw ZennopayError.intentMismatch
        }

        // `exp` is seconds-since-epoch per RFC 7519. Accept either Int or
        // Double for resilience against JSON encoders that emit floats.
        let expSeconds: Double
        if let expInt = claims["exp"] as? Int {
            expSeconds = Double(expInt)
        } else if let expDouble = claims["exp"] as? Double {
            expSeconds = expDouble
        } else {
            throw ZennopayError.jwtMissingClaim
        }

        let expiresAt = Date(timeIntervalSince1970: expSeconds)
        if expiresAt.addingTimeInterval(clockSkewTolerance) < now {
            throw ZennopayError.jwtExpired
        }

        guard let issuer = claims["iss"] as? String, !issuer.isEmpty else {
            throw ZennopayError.jwtMissingClaim
        }

        return Decoded(intentID: claimIntentID, expiresAt: expiresAt, issuer: issuer)
    }

    // MARK: - base64url

    /// Decode a base64url-encoded string (no padding, `-`/`_` instead of
    /// `+`/`/`) to raw bytes. Returns nil if the input isn't valid base64.
    static func base64URLDecode(_ input: String) -> Data? {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4. Standard base64 requires this; base64url
        // omits it.
        let remainder = s.count % 4
        if remainder > 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: s)
    }
}
