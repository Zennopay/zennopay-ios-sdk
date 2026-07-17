#if DEBUG
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// DEBUG-only screen gallery: renders any PaymentSheet screen with injected
/// mock state — NO network, NO camera prompt, NO money movement. Compiled out
/// of release builds entirely (`#if DEBUG`).
///
/// The demo host exposes it behind the `ZP_DEBUG_GALLERY` launch environment
/// variable with the spec format `<screen>[:<variant>]`:
///
///   screen:   scanner | keypad | review | breakdown | processing | receipt
///             | failure | pending
///   variant:  vnd35     ₫3,500,000 / $140.00      (the demo amount)
///             vndmax    ₫4,999,999 / $200.00      (max under the ₫5M cap)
///             vndhuge   ₫999,999,999 / $99,999.99 (defensive overflow probe)
///             thbmax    ฿999,999.99 / $28,571.43  (2-decimal currency)
///
/// Example: `ZP_DEBUG_GALLERY=review:vndhuge`.
public enum ZennopayDebugGallery {

    /// Build the gallery root for a spec string. Returns nil for an
    /// unrecognized spec (the host should fall back to its normal UI).
    @MainActor
    public static func rootView(
        spec: String, appearance: ZennopayAppearance = .default
    ) -> AnyView? {
        guard #available(iOS 16.0, *) else { return nil }
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        guard let screen = parts.first?.lowercased(), !screen.isEmpty else { return nil }
        let variant = Variant(rawValue: parts.count > 1 ? parts[1].lowercased() : "vnd35")
            ?? .vnd35
        let theme = ZTheme(appearance: appearance)

        // Breakdown is a sheet, not a state — render it directly.
        if screen == "breakdown" {
            return AnyView(
                FeeBreakdownSheet(quote: variant.quote, theme: theme)
                    .preferredColorScheme(theme.forcedColorScheme)
            )
        }

        guard let state = galleryState(screen: screen, variant: variant) else { return nil }
        let vm = frozenViewModel(theme: theme, state: state, variant: variant, screen: screen)
        return AnyView(CheckoutContainerView(vm: vm))
    }

    // MARK: - Variants

    enum Variant: String {
        case vnd35, vndmax, vndhuge, thbmax

        /// (localMinorUnits, numericCurrency, usdCents)
        var amounts: (local: Int, currency: String, usd: Int) {
            switch self {
            case .vnd35:   return (350_000_000, "704", 14_000)
            case .vndmax:  return (499_999_900, "704", 20_000)
            case .vndhuge: return (99_999_999_900, "704", 9_999_999)
            case .thbmax:  return (99_999_999, "764", 2_857_143)
            }
        }

        var corridor: String { self == .thbmax ? "th_promptpay" : "vn_vietqr" }

        var merchantName: String {
            self == .thbmax ? "Chatuchak Coffee Roasters" : "Cà Phê Sài Gòn"
        }

        var quote: CheckoutState.Quote {
            let a = amounts
            return CheckoutState.Quote(
                from: ScanResponse(
                    intent_id: "zp_debug_gallery",
                    status: "created",
                    merchant: ScanResponse.Merchant(
                        scheme: self == .thbmax ? "promptpay" : "vietqr",
                        name: merchantName,
                        city: self == .thbmax ? "Bangkok" : "Ho Chi Minh City",
                        country: self == .thbmax ? "TH" : "VN",
                        mcc: "5814"
                    ),
                    qr_kind: "dynamic",
                    quote: ScanResponse.Quote(
                        quote_id: "q_debug",
                        quote_version: 1,
                        amount_usd_cents: a.usd,
                        local_amount_minor_units: a.local,
                        local_currency: a.currency,
                        // Far-future expiry so the review ticker never
                        // triggers a (frozen, no-op) refresh.
                        expires_at: Int(Date().timeIntervalSince1970 * 1000) + 86_400_000
                    )
                ),
                defaultTTL: 86_400
            )
        }

        var peek: QRPayload.Peek {
            self == .thbmax
                ? QRPayload.Peek(isStatic: false, bankBIN: nil, accountNumber: nil)
                : QRPayload.Peek(
                    isStatic: false, bankBIN: "970436", accountNumber: "10230203300000"
                )
        }

        var snapshot: IntentSnapshot {
            let a = amounts
            return IntentSnapshot(
                id: "zp_debug_gallery",
                status: "captured",
                amount_usd_cents: a.usd,
                corridor: corridor,
                merchant: IntentSnapshot.ConfirmMerchant(
                    scheme: self == .thbmax ? "promptpay" : "vietqr",
                    name: merchantName,
                    city: nil, country: nil, mcc: nil,
                    currency_numeric: a.currency
                ),
                qr_kind: "dynamic",
                quote_id: "q_debug",
                quote_version: 1,
                quote_local_amount_minor_units: a.local,
                quote_local_currency: a.currency,
                quote_expires_at: nil,
                confirm_state: "captured",
                beneficiary: nil,
                transaction_id: "9p_txn_debug_000042",
                created_at: nil,
                updated_at: nil
            )
        }
    }

    // MARK: - Assembly

    private static func galleryState(screen: String, variant: Variant) -> CheckoutState? {
        switch screen {
        case "scanner":    return .scanning
        case "keypad":     return .amountEntry(rawPayload: Self.staticDemoQR)
        case "review":     return .quoted(variant.quote)
        case "processing": return .awaitingResult
        case "receipt":    return .finished(.completed(intentID: "zp_debug_gallery"))
        case "failure":
            return .finished(.failed(intentID: "zp_debug_gallery", error: .paymentFailed))
        case "pending":    return .finished(.pending(intentID: "zp_debug_gallery"))
        default:           return nil
        }
    }

    @MainActor
    private static func frozenViewModel(
        theme: ZTheme, state: CheckoutState, variant: Variant, screen: String
    ) -> CheckoutViewModel {
        let config = ZennopayConfig(apiBaseURL: URL(string: "https://invalid.zennopay.test")!)
        let client = RESTClient(
            config: config,
            intentID: "zp_debug_gallery",
            sessionJWT: "debug",
            refreshSession: nil,
            transport: GalleryNoopTransport()
        )
        let store = IdempotencyStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("zp-debug-gallery-\(UUID().uuidString)")
        )
        let vm = CheckoutViewModel(
            intentID: "zp_debug_gallery",
            config: config,
            client: client,
            store: store,
            theme: theme,
            corridor: variant.corridor,
            onResult: { _ in }
        )
        let terminal = ["receipt", "failure", "pending"].contains(screen)
        vm.debugApply(
            state: state,
            quote: variant.quote,
            snapshot: terminal ? variant.snapshot : nil,
            peek: variant.peek,
            corridor: variant.corridor,
            purpose: screen == "receipt" ? "Coffee with the team" : "",
            walletDebited: terminal,
            confirmedAt: terminal ? Date() : nil
        )
        return vm
    }

    /// A static VietQR (no tag 54) so the keypad screen has a real payload.
    static let staticDemoQR =
        "00020101021238570010A00000072701270006970436011310230203300000208QRIBFTTA53037045802VN6304"
}

/// Transport that fails everything instantly — the gallery must never reach
/// the network (the frozen view model never calls it anyway).
private struct GalleryNoopTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
#endif
#endif
