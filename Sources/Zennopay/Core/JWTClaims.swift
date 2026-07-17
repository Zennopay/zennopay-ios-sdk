import Foundation

/// Lightweight, on-device inspection of a session JWT's payload claims.
///
/// We **do not** verify the JWT signature here — the Zennopay backend is the
/// authority on signature/issuer validity (RS256, `jti` single-use, intent
/// binding). The SDK's job is to fail fast on the client when the host hands us
/// a token obviously bound to the wrong intent, expired, or structurally
/// broken, so we never make a doomed REST call.
///
/// Claim contract (see `backend/src/auth/jwt.ts` `ZennopayJwtClaims`):
///   iss, aud, iat, exp, jti, `zennopay:intent_id`.
/// `aud` must be `zennopay-checkout` (auth spec §2.3).
internal enum JWTClaims {

    /// Expected audience for a Zennopay session JWT (auth spec §2.3).
    static let expectedAudience = "zennopay-checkout"

    /// Decoded claim bag for the claims the SDK cares about.
    struct Decoded: Equatable {
        let intentID: String
        let expiresAt: Date
        let issuer: String
        let audience: String
        let jti: String
        /// Optional `zennopay:corridor` claim (e.g. "vn_vietqr"). Drives the
        /// corridor-aware scanner branding row; absent on older tokens.
        let corridor: String?
    }

    /// Decode and validate the payload segment against the supplied intent and
    /// clock.
    ///
    /// - Parameters:
    ///   - jwt: The raw `header.payload.signature` string.
    ///   - expectedIntentID: Must equal `zennopay:intent_id` exactly.
    ///   - now: Injectable clock for tests.
    ///   - clockSkewTolerance: How far past `exp` we still accept (default 30s).
    /// - Throws: A `ZennopayError` describing the first failure.
    static func validate(
        jwt: String,
        expectedIntentID: String,
        now: Date = Date(),
        clockSkewTolerance: TimeInterval = 30
    ) throws -> Decoded {
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

        // Namespaced custom claim; colon is legal in JSON keys.
        guard let claimIntentID = claims["zennopay:intent_id"] as? String,
              !claimIntentID.isEmpty else {
            throw ZennopayError.jwtMissingClaim
        }

        // Intent mismatch is checked before exp so a stale-token-for-new-intent
        // surfaces the more actionable error.
        guard claimIntentID == expectedIntentID else {
            throw ZennopayError.intentMismatch
        }

        // exp is seconds-since-epoch (RFC 7519). Accept Int or Double.
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

        guard let audience = claims["aud"] as? String, !audience.isEmpty else {
            throw ZennopayError.jwtMissingClaim
        }

        // jti is required by the contract but empty/missing is treated as a
        // missing claim (the backend will reject anyway).
        guard let jti = claims["jti"] as? String, !jti.isEmpty else {
            throw ZennopayError.jwtMissingClaim
        }

        return Decoded(
            intentID: claimIntentID,
            expiresAt: expiresAt,
            issuer: issuer,
            audience: audience,
            jti: jti,
            corridor: claims["zennopay:corridor"] as? String
        )
    }

    // MARK: - base64url

    /// Decode a base64url string (no padding, `-`/`_` for `+`/`/`).
    static func base64URLDecode(_ input: String) -> Data? {
        var s = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: s)
    }
}
