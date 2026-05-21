import Foundation

/// Errors surfaced by the Zennopay SDK to the host application.
public enum ZennopayError: Error, Equatable {
    /// The JWT supplied to `openCheckout` was empty or otherwise malformed.
    /// JWT structural validation is intentionally minimal — the checkout web
    /// is the source of truth — but we reject obviously-empty tokens up-front.
    case invalidJWT

    /// The JWT is not a syntactically valid token (wrong segment count,
    /// undecodable base64, payload is not a JSON object). Distinct from
    /// `invalidJWT` (which covers the empty/whitespace case) so the host can
    /// distinguish "you passed nothing" from "you passed garbage".
    case malformedToken

    /// The JWT's `zennopay:intent_id` claim does not match the `intentID`
    /// argument passed to `openCheckout`. This means the host is about to
    /// open a checkout for one intent while authenticating with a token
    /// minted for a different intent — a JWT-replay-across-intents bug we
    /// fail fast on before opening the browser.
    case intentMismatch

    /// The JWT's `exp` claim is in the past (with a small clock-skew
    /// tolerance). The host should mint a fresh token from its backend and
    /// retry.
    case jwtExpired

    /// The JWT is missing a required claim (`zennopay:intent_id`, `exp`, or
    /// has an empty `iss`). Surfaced separately from `malformedToken` so the
    /// host can tell "the token parsed but lacks fields we need" from "the
    /// token is unparseable garbage".
    case jwtMissingClaim

    /// The user dismissed the system browser sheet without completing checkout.
    case userCanceled

    /// The redirect URL came back missing required parameters (`intent_id`
    /// and/or `status`) or with an unrecognized status value.
    case returnURLMalformed

    /// No presentation anchor was available and the SDK could not find a
    /// suitable window to present the auth session over. The host should
    /// pass an explicit `presentationContext`.
    case presentationAnchorMissing

    /// An underlying network or AuthenticationServices error that doesn't
    /// fit one of the more specific cases above.
    case networkError(Error)

    public static func == (lhs: ZennopayError, rhs: ZennopayError) -> Bool {
        switch (lhs, rhs) {
        case (.invalidJWT, .invalidJWT),
             (.malformedToken, .malformedToken),
             (.intentMismatch, .intentMismatch),
             (.jwtExpired, .jwtExpired),
             (.jwtMissingClaim, .jwtMissingClaim),
             (.userCanceled, .userCanceled),
             (.returnURLMalformed, .returnURLMalformed),
             (.presentationAnchorMissing, .presentationAnchorMissing):
            return true
        case (.networkError(let l), .networkError(let r)):
            return (l as NSError) == (r as NSError)
        default:
            return false
        }
    }
}
