#if canImport(SwiftUI)
import SwiftUI

/// Root container for the `presentReceipt` flow. Reuses the checkout terminal
/// screens verbatim: a captured/refunded receipt renders `ReceiptScreen`, a
/// failed receipt renders `FailureScreen`, and a still-processing receipt
/// renders `PendingDetailScreen` while the view model polls. Before the first
/// fetch resolves it shows a lightweight loading state.
///
/// Presented modally by `Zennopay.presentReceipt`. Mirrors
/// `CheckoutContainerView`'s chrome (themed background + Powered-by footer).
@available(iOS 14.0, macOS 13.0, *)
struct ReceiptContainerView: View {
    @ObservedObject var vm: CheckoutViewModel

    private var theme: ZTheme { vm.theme }

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                content
                PoweredByZennopay(theme: theme)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
            }
        }
        .preferredColorScheme(theme.forcedColorScheme)
        .task { await vm.runReceiptFlow(preflightError: vm.receiptPreflightError) }
    }

    @ViewBuilder
    private var content: some View {
        switch vm.state {
        case .finished(let result):
            ResultScreen(result: result, vm: vm)
        default:
            ReceiptLoadingScreen(theme: theme)
        }
    }
}

/// The receipt's initial loading state: a themed spinner while the authoritative
/// receipt is fetched. Distinct copy from the checkout "Payment processing…"
/// card — here we are reopening an existing payment, not making one.
@available(iOS 14.0, macOS 13.0, *)
struct ReceiptLoadingScreen: View {
    let theme: ZTheme

    var body: some View {
        VStack(spacing: ZTokens.md) {
            Spacer()
            ProgressView()
                .scaleEffect(1.4)
                .tint(theme.accent)
            Text("Loading your receipt…")
                .zpFont(theme, 15)
                .foregroundColor(theme.text2)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading your receipt")
        .accessibilityIdentifier("zp.receipt.loading")
    }
}
#endif
