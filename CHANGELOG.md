# Changelog

All notable changes to the Zennopay iOS SDK are documented here.

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
