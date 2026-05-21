# Zennopay iOS SDK

Official iOS SDK for [Zennopay](https://zennopay.com) cross-border QR payments.
A thin, dependency-free wrapper that lets a partner app (e.g. Wizz) hand off a
payment intent to the Zennopay hosted checkout. Modeled on the Stripe Checkout
pattern, it opens the checkout URL in a system browser tab via
`ASWebAuthenticationSession` so the user always sees a real URL bar and an
Apple-mediated consent sheet. When checkout completes, the browser redirects
back to the partner app via a registered URL scheme and the SDK surfaces a
typed `PaymentResult`.

Full documentation: [docs.zennopay.com](https://docs.zennopay.com)

## Requirements

- iOS 13.0+
- Swift 5.9+
- No third-party dependencies (only Foundation + AuthenticationServices)

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and paste the repository URL:

```
https://github.com/amanpal108/zennopay-ios-sdk
```

Select the `Zennopay` library product and add it to your app target.

If you maintain your own `Package.swift`, declare:

```swift
.package(url: "https://github.com/amanpal108/zennopay-ios-sdk", from: "0.1.0")
```

and add `"Zennopay"` to your target's dependencies.

## URL scheme registration

The SDK delivers the payment result by redirecting from the checkout web to a
URL scheme your app owns. Register it in your `Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key>
    <string>com.wizz.payment-result</string>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>wizz</string>
    </array>
  </dict>
</array>
```

The redirect URL the checkout web will fire is
`wizz://payment-result?intent_id=...&status=...`. You do not need to handle
this URL in your `SceneDelegate` / `AppDelegate` — `ASWebAuthenticationSession`
captures it before it reaches the OS routing layer and delivers it directly to
the SDK's completion handler.

## Usage

```swift
import Zennopay

Zennopay.openCheckout(
    intentID: "zp_abc123",
    jwt: jwtFromBackend,
    returnScheme: "wizz"
) { result in
    switch result {
    case .success(let r):
        print("Payment \(r.status) for intent \(r.intentID)")
    case .failure(let e):
        print("Error: \(e)")
    }
}
```

The completion handler is delivered on the main queue.

### Async/await

A Swift Concurrency variant is also available:

```swift
do {
    let result = try await Zennopay.openCheckout(
        intentID: "zp_abc123",
        jwt: jwtFromBackend,
        returnScheme: "wizz"
    )
    print("Payment \(result.status) for intent \(result.intentID)")
} catch {
    print("Error: \(error)")
}
```

## How it works

1. The host's backend exchanges its Zennopay API key for a short-lived JWT
   scoped to one `intent_id`.
2. The host calls `Zennopay.openCheckout(...)` with that JWT.
3. The SDK verifies the JWT's `intent_id` claim matches the call site's
   `intentID` argument before opening the browser. Mismatch raises
   `ZennopayError.invalidJWT` synchronously.
4. The SDK opens `https://checkout.zennopay.com/flow/{intent_id}/scan#token={jwt}`
   in `ASWebAuthenticationSession`. The token rides in the URL **fragment**
   (after `#`), so it is never sent to the HTTP server in logs or to proxies.
5. The user completes (or cancels) checkout in the system browser.
6. The checkout web redirects to `wizz://payment-result?intent_id=...&status=...`.
7. The SDK parses the redirect and calls your completion handler with a
   `PaymentResult` (or a `ZennopayError`).

## Result + error types

```swift
public enum PaymentStatus: String { case success, failed, canceled, pending }

public struct PaymentResult {
    public let intentID: String
    public let status: PaymentStatus
}

public enum ZennopayError: Error {
    case invalidJWT
    case userCanceled
    case returnURLMalformed
    case presentationAnchorMissing
    case networkError(Error)
}
```

`.pending` means the checkout web could not synchronously confirm the
outcome (async settlement, provider review, etc.). The host should poll the
intent or wait for a webhook for the final state.

## License

MIT — see [LICENSE](LICENSE).
