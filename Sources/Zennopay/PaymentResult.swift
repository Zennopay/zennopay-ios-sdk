import Foundation

/// Terminal (or near-terminal) status of a Zennopay payment attempt as reported
/// back to the host application via the return URL.
public enum PaymentStatus: String, Equatable, Sendable {
    /// Payment captured successfully and funds are committed to the destination.
    case success
    /// Payment was attempted but rejected by the network, provider, or risk engine.
    case failed
    /// User explicitly canceled the checkout flow before completion.
    case canceled
    /// Payment is in a pending state (e.g. async settlement, provider review).
    /// The host should poll the intent or wait for a webhook for the final outcome.
    case pending
}

/// Result delivered to the host when the Zennopay checkout flow completes and
/// the system browser redirects back into the partner app.
public struct PaymentResult: Equatable, Sendable {
    /// The Zennopay payment intent identifier that was checked out.
    public let intentID: String

    /// The status reported by the checkout web at the moment of redirect.
    public let status: PaymentStatus

    public init(intentID: String, status: PaymentStatus) {
        self.intentID = intentID
        self.status = status
    }
}
