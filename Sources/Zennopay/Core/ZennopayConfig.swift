import Foundation

/// SDK configuration. The API base URL is injectable so tests (and staging /
/// prod / on-prem deployments) can point the SDK at a different host without a
/// recompile. Defaults to the Zennopay staging gateway.
public struct ZennopayConfig: Sendable {

    /// Base URL for the SDK-facing REST surface (`/v1/payment_intents/...`).
    /// No trailing slash.
    public let apiBaseURL: URL

    /// How long to keep polling `GET /:id` for a terminal state before giving
    /// up and surfacing `.timedOut`. The provider payout is async, so we allow
    /// a generous budget.
    public let statusPollTimeout: TimeInterval

    /// Ceiling on a single status-poll backoff step (seconds).
    public let maxPollInterval: TimeInterval

    /// Quote validity window from `/scan` (seconds). Drives the silent-refresh
    /// countdown on the amount screen. The backend is authoritative; this is a
    /// client-side default used only until the first quote arrives with its own
    /// `expires_at`.
    public let defaultQuoteTTL: TimeInterval

    public init(
        apiBaseURL: URL,
        statusPollTimeout: TimeInterval = 90,
        maxPollInterval: TimeInterval = 4,
        defaultQuoteTTL: TimeInterval = 30
    ) {
        self.apiBaseURL = apiBaseURL
        self.statusPollTimeout = statusPollTimeout
        self.maxPollInterval = maxPollInterval
        self.defaultQuoteTTL = defaultQuoteTTL
    }

    /// Default staging configuration. Matches the base the checkout SPA and
    /// backend use on staging. Override via `presentCheckout(..., config:)` for
    /// prod or local development.
    public static let staging = ZennopayConfig(
        apiBaseURL: URL(string: "https://api.staging.zennopay.in")!
    )
}
