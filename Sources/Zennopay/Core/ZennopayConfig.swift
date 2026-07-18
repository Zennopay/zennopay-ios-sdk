import Foundation

/// SDK configuration. The API base URL is injectable so tests (and sandbox /
/// production / on-prem deployments) can point the SDK at a different host
/// without a recompile. Defaults to the Zennopay sandbox gateway.
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

    /// Default **sandbox** configuration. Points at the Zennopay sandbox
    /// gateway (`https://api.sandbox.zennopay.in`) — the environment partners
    /// integrate and test against. Override via `presentCheckout(..., config:)`
    /// with `.production` for live traffic, or a custom config for on-prem /
    /// local development.
    public static let sandbox = ZennopayConfig(
        apiBaseURL: URL(string: "https://api.sandbox.zennopay.in")!
    )

    /// **Production** configuration. Points at the live Zennopay gateway
    /// (`https://api.zennopay.in`). Use for real, money-moving traffic once
    /// your integration is certified.
    public static let production = ZennopayConfig(
        apiBaseURL: URL(string: "https://api.zennopay.in")!
    )

    /// Deprecated alias for ``sandbox``. Retained so existing integrations keep
    /// compiling; now resolves to the sandbox gateway
    /// (`https://api.sandbox.zennopay.in`).
    @available(*, deprecated, renamed: "sandbox")
    public static let staging = sandbox
}
