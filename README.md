# Zennopay iOS SDK

The iOS SDK for [Zennopay](https://zennopay.in) — let your app's users scan
local merchant QR codes abroad and pay from their wallet balance.

The SDK presents the **PaymentSheet**: the full native pay experience — QR
scan → amount + FX quote → slide-to-pay → result — modally over your view
controller, and delivers exactly one typed `PaymentResult` to your callback.
It is SwiftUI under the hood, dependency-free, and works from both UIKit and
SwiftUI hosts.

Full documentation: [Zennopay/zennopay-docs](https://github.com/Zennopay/zennopay-docs)

## Requirements

- iOS 16.0+ (the presented flow uses modern SwiftUI APIs)
- Swift 5.9+ / Xcode 15+
- No third-party dependencies
- A backend session endpoint that creates the payment intent by calling
  Zennopay's `POST /v1/payment_intents` (HMAC-signed, server-to-server) and
  relays the returned Zennopay-minted `session_token` to the sheet — no JWT
  keypair to generate or register (your API keys never ship in the app). See
  the [partner-starter](https://github.com/Zennopay/zennopay-partner-starter)
  (v0.2.0+) for a reference backend.

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and paste:

```
https://github.com/Zennopay/zennopay-ios-sdk
```

Select **Up to Next Major Version**, then add the `Zennopay` library product
to your app target. Or, in your own `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Zennopay/zennopay-ios-sdk", from: "0.7.0")
],
targets: [
    .target(name: "YourApp", dependencies: ["Zennopay"])
]
```

### Declare camera usage

The sheet opens on a live camera scanner. iOS reads the permission prompt's
usage string from **your** app bundle, so add to your `Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Scan a merchant QR code to pay.</string>
```

If the user denies camera access (or the device has no camera), the sheet
automatically falls back to a paste-QR-data field — the flow is always
completable without a camera.

## Quickstart

Ask your backend for a checkout session — it calls Zennopay's
`POST /v1/payment_intents` (HMAC) and returns the intent id plus the
Zennopay-minted `session_token` — then present the sheet:

```swift
import Zennopay

Zennopay.presentCheckout(
    from: self,                          // host UIViewController
    intentID: session.intentId,
    sessionJWT: session.sessionJwt,
    refreshSession: { intentID in
        // Called on session expiry (401): ask your backend for a fresh
        // session_token for the SAME intent (it re-calls Zennopay's session
        // endpoint), or return nil if you can't.
        try? await api.refreshSessionToken(for: intentID)
    },
    config: .sandbox                     // .production for live traffic
) { result in
    switch result {
    case .completed(let intentID):
        showReceipt(intentID: intentID)  // money moved — debit your ledger
    case .canceled:
        break                            // user backed out; no money moved
    case .failed(let intentID, let error):
        log("payment failed", intentID, error)
    }
}
```

The SDK validates the JWT's structure, expiry, and intent binding **before**
presenting any UI, so a mis-paired token fails fast with `.failed` instead
of an empty sheet. Slide-to-pay fires the confirm exactly once — the
idempotency key is persisted before the network call, so retries and process
death can never double-debit.

`ZennopayError` is a typed taxonomy (`invalidJWT`, `intentMismatch`,
`jwtExpired`, `sessionExpired`, `quoteExpired`, `paymentFailed`, `timedOut`,
`networkError`, …). On `.timedOut` the payment is effectively *pending* — it
may still settle; reconcile via your webhook or `GET /v1/payment_intents/:id`
rather than assuming a terminal failure.

### Reopen a receipt

Show the **authoritative** Zennopay receipt for a past payment — with live
pending/refund status — from anywhere in your app (an order history row, a
push-notification tap). Mint a short-lived **receipt token** on your backend
(your partner JWT keypair — the one flow that still uses it, since the session
token is now Zennopay-minted — with `aud = zennopay-receipt`,
`sub = <partner_user_id>`, ≤15-min exp, reusable so the SDK can poll) and
hand it to the app alongside the intent id:

```swift
import Zennopay

Zennopay.presentReceipt(
    from: self,                          // host UIViewController
    intentID: order.intentId,
    receiptToken: order.receiptToken,    // minted by your backend (aud=zennopay-receipt)
    refreshReceiptToken: { intentID in
        // Called on token expiry (401): re-mint a fresh receipt token, or nil.
        try? await api.mintReceiptToken(for: intentID)
    },
    config: .sandbox                     // .production for live traffic
) {
    // Called after the user taps Done / close (or the token failed to load).
}
```

The SDK fetches the receipt and renders the terminal screen for you: a
**captured** payment shows the receipt, a **refunded** payment shows it with
refund messaging, a **failed** payment shows the failure screen, and a
still-**pending** payment shows the processing detail and polls until it goes
terminal. Like `presentCheckout`, your API keys never ship in the app — only
the short-lived, per-user receipt token does. The backend is authoritative:
a 404 is returned for an unknown intent *or* one that isn't this user's, with
no existence leak.

### Environments

`ZennopayConfig` selects the environment. It is a value, never a code path:

```swift
config: .sandbox       // https://api.sandbox.zennopay.in — SANDBOX pill shown (default)
config: .production    // https://api.zennopay.in — real money, no sandbox chrome
config: ZennopayConfig(apiBaseURL: URL(string: "http://localhost:3000")!)  // custom gateway
```

> `.staging` is **deprecated** — it is a compatibility alias for `.sandbox`
> (same host, `https://api.sandbox.zennopay.in`). Existing code keeps working;
> migrate to `.sandbox` at your convenience.

### Theming

`ZennopayAppearance` themes the sheet to match your app — colors, corner
radii, font, primary button, and an optional logo in the sheet header:

```swift
var appearance = ZennopayAppearance()
appearance.colors.primary = UIColor(named: "BrandGreen")!
appearance.primaryButton = .init(
    background: UIColor(named: "BrandGreen")!,
    textColor: .white,
    cornerRadius: 10
)
appearance.logo = UIImage(named: "wordmark")
```

Pass nothing for the default Zennopay look, following system light/dark.
Structural rules are not overridable: radii are clamped to ≤ 12 pt, amounts
always render in tabular figures, and the accent color is reserved for state
signals.

## Testing

The Simulator has no camera — the sheet swaps in the paste-QR fallback
automatically; paste any VietQR/EMVCo payload string and the flow proceeds
identically (the backend does the authoritative parse either way). On a
physical device, camera scanning and the runtime-permission prompt are the
pre-release checklist.

## Versioning

Zennopay SDKs follow [semver](https://semver.org). `v0.x` releases are
pre-GA: minor versions may contain breaking API changes, called out in the
[CHANGELOG](CHANGELOG.md).

All four Zennopay SDKs — iOS,
[Android](https://github.com/Zennopay/zennopay-android-sdk),
[Flutter](https://github.com/Zennopay/zennopay-flutter-sdk), and
[React Native](https://github.com/Zennopay/zennopay-react-native-sdk) — release
in lockstep: the same `vX.Y.Z` tag and GitHub Release is cut in each repo
per release. These standalone repos are release mirrors (squashed release
commits, not full development history).

## License

MIT — see [LICENSE](LICENSE).
