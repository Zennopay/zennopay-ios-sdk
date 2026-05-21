# Changelog

All notable changes to the Zennopay iOS SDK are documented here.

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
