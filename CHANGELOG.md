# Changelog

All notable changes to the Zennopay iOS SDK are documented here.

## 0.5.0 - 2026-07-18

Version-aligned across all SDKs; API domain zennopay.com → zennopay.in
(canonical). No API changes.

## 0.3.0 - 2026-07-18

`presentReceipt` — reopen the authoritative Zennopay receipt for any past
payment, with live pending/refund status.

### Added

- `Zennopay.presentReceipt(from:intentID:receiptToken:refreshReceiptToken:config:appearance:onDismiss:)`
  — presents the authoritative receipt for a past payment over your view
  controller. A captured payment shows the receipt; a refunded payment shows
  it with refund messaging; a failed payment shows the failure screen; a still
  -processing payment shows the pending detail and polls until it resolves.
  Reuses the redesigned receipt screens, appearance theming, and the
  Powered-by-Zennopay footer.
- Fetches `GET /v1/payment_intents/:id/receipt`, authenticated by a
  partner-minted RS256 **receipt token** (`aud = zennopay-receipt`,
  `sub = partner_user_id`, ≤15-min exp, reusable for polling). A 401 mid-poll
  triggers `refreshReceiptToken` (if provided) then retries; the backend
  remains authoritative (401 = bad/expired token, 404 = unknown intent or not
  this user, with no existence leak).

`presentCheckout` is unchanged and fully source-compatible.

## 0.2.1 - 2026-07-18

Distribution: the SDK is now publishable to CocoaPods trunk in addition to
Swift Package Manager. No API changes.

### Added

- `Zennopay.podspec` for CocoaPods (`pod 'Zennopay'`), unblocking the React
  Native and Flutter bridges whose iOS sides depend on the pod.
- `Bundle.module` resolution shim (guarded by `!SWIFT_PACKAGE`) so the
  "Powered by Zennopay" asset catalog loads under both SwiftPM and CocoaPods.
  Under CocoaPods the assets ship in a `ZennopayResources` resource bundle.

## 0.2.0 - 2026-07-17

The PaymentSheet release: the SDK now renders the entire native pay
experience in-process. The hosted-checkout (browser handoff) model from
0.1.0 is removed.

### Added

- `Zennopay.presentCheckout(from:intentID:sessionJWT:refreshSession:appearance:config:onResult:)`
  — single native entrypoint; scan → review → slide-to-pay → result.
- Full-screen scanner: corner-bracket reticle, animated scan line,
  corridor-aware scheme chips, gallery QR import, torch, paste-code
  fallback (simulator-friendly), help sheet.
- Review screen: local-currency-primary amount, merchant card with
  verification badge, tappable fee breakdown (FX rate, fees, offers),
  optional purpose-of-payment note.
- Static-QR keypad with per-transaction limit enforcement.
- Processing / delayed / pending states with honest copy; `PaymentResult.pending`.
- Persistent shareable receipt (explicit Done, no auto-dismiss).
- `ZennopayAppearance` partner theming (colors, corner radius, fonts,
  primary button, light/dark) with dynamic light/dark defaults.
- Accessibility: Dynamic Type scaling (capped for chrome), VoiceOver
  labels + double-tap-to-confirm on slide, Reduce Motion support,
  WCAG AA contrast tokens, 44pt hit targets.
- "Powered by Zennopay" footer on every screen.

### Removed

- `ASWebAuthenticationSession` hosted checkout, URL-scheme redirect flow.

## 0.1.0 - 2026-05-21

Initial public release.

### Added

- `Zennopay.openCheckout(...)` — Stripe-Checkout-style payment handoff via
  `ASWebAuthenticationSession`. Token rides in the URL fragment, never sent to
  the server in headers or proxy logs.
- **JWT → intent_id binding**: the SDK now decodes the JWT and verifies its
  `intent_id` claim matches the `intentID` argument before opening the
  browser. A mismatch raises `ZennopayError.invalidJWT` synchronously,
  preventing a malformed call site from leaking a token scoped to a different
  intent.
- Async/await variant of `openCheckout`.
- Typed `PaymentResult` / `PaymentStatus` / `ZennopayError`.
