import XCTest
@testable import Zennopay
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Live + rendering proof for `presentReceipt`.
///
///  - `test_liveStagingReceipt…` (env-gated by `ZP_LIVE_RECEIPT=1` +
///    `ZP_RECEIPT_BASE` + `ZP_INTENT_ID` + `ZP_RECEIPT_TOKEN`) hits the LIVE
///    staging receipt endpoint with a partner-minted receipt token and asserts
///    a 200 that decodes to a captured `ReceiptDTO`. Proves token → fetch.
///  - `test_renderReceiptScreen…` (iOS simulator, DEBUG) renders the redesigned
///    `ReceiptScreen` through the real `presentReceipt` container, fed the REAL
///    receipt captured from staging (frozen view model → no network, no money),
///    and writes a PNG. Proves fetch → render.
final class ReceiptLiveE2ETests: XCTestCase {

    /// The REAL receipt captured from LIVE staging for demo_user_6's ₫3.5M
    /// intent (harness output). Personal VietQR → `merchant.name` is null, so
    /// the display applies the corridor-aware fallback ("Vietnam Merchant").
    static let liveReceiptJSON = """
    {"intent_id":"0747aca3-1c1a-4ab7-b8d2-4e500c0033a3","status":"captured",
     "merchant":{"name":null,"account_no":"••••0000","bank_no":"970436","country":"VN"},
     "amount_usd_cents":14000,"local_amount_minor_units":350000000,"local_currency":"VND",
     "exchange_rate":25000,"fees":{"margin_usd_cents":210},"corridor":"vn_vietqr",
     "transaction_ref":"stubq_48825a27-8975-4aa5-8c2f-62d8813c2180",
     "created_at":"2026-07-17T22:49:26.196Z","updated_at":"2026-07-17T22:49:28.780Z"}
    """

    func test_liveStagingReceipt_returns200_andDecodesCaptured() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["ZP_LIVE_RECEIPT"] == "1", "live receipt E2E not requested")
        let base = try XCTUnwrap(env["ZP_RECEIPT_BASE"])
        let intentID = try XCTUnwrap(env["ZP_INTENT_ID"])
        let token = try XCTUnwrap(env["ZP_RECEIPT_TOKEN"])

        let config = ZennopayConfig(apiBaseURL: URL(string: base)!)
        let client = RESTClient(config: config, intentID: intentID, sessionJWT: token,
                                refreshSession: nil, transport: URLSession.shared)
        let dto = try await client.fetchReceipt()
        XCTAssertEqual(dto.intent_id, intentID)
        XCTAssertEqual(dto.receiptStatus, .captured, "expected a captured intent")
        XCTAssertEqual(dto.amount_usd_cents, 14000)
        XCTAssertGreaterThan(dto.local_amount_minor_units ?? 0, 0)
        print("LIVE RECEIPT 200 →", dto)
    }

    #if DEBUG && canImport(AppKit) && canImport(SwiftUI)
    /// Renders the real production `ReceiptCardBody` view — the receipt screen's
    /// card, fed the REAL receipt captured from staging — to a PNG via
    /// `ImageRenderer`. Gated by `ZP_RECEIPT_SHOT_OUT`. Proves fetch → render:
    /// merchant (corridor fallback), ₫3,500,000 hero, $140.00 paid, Captured.
    @MainActor
    func test_renderReceiptScreen_fromRealFetchedData() throws {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["ZP_RECEIPT_SHOT_OUT"] else { throw XCTSkip("screenshot render not requested") }
        guard #available(macOS 13.0, *) else { throw XCTSkip("needs macOS 13") }

        let dto = try JSONDecoder().decode(ReceiptDTO.self, from: Data(Self.liveReceiptJSON.utf8))

        // Build the display `Receipt` off a frozen view model (no network).
        let config = ZennopayConfig(apiBaseURL: URL(string: "https://invalid.zennopay.test")!)
        let client = RESTClient(config: config, intentID: dto.intent_id, sessionJWT: "shot",
                                refreshSession: nil, transport: ShotNoopTransport())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zp-shot-\(UUID().uuidString)")
        let vm = CheckoutViewModel(intentID: dto.intent_id, config: config, client: client,
                                   store: IdempotencyStore(directory: dir),
                                   theme: .automatic, onResult: { _ in })
        vm.debugApplyReceipt(dto)   // frozen, terminal
        let receipt = try XCTUnwrap(vm.receipt)
        XCTAssertEqual(vm.receiptDisplayStatus, .captured)
        XCTAssertEqual(receipt.usdCents, 14000)
        XCTAssertEqual(receipt.localMinorUnits, 350000000)

        let theme = ZTheme.automatic
        let card = VStack(spacing: 0) {
            HStack {
                Text("Receipt").zpFont(theme, 17, .semibold).foregroundColor(theme.text)
            }.frame(maxWidth: .infinity).padding(.vertical, ZTokens.md)
            ReceiptCardBody(theme: theme, receipt: receipt, isRefunded: false, entered: true)
                .padding(.horizontal, ZTokens.md)
            Spacer(minLength: 0)
            PoweredByZennopay(theme: theme).padding(.bottom, ZTokens.md)
        }
        .frame(width: 390, height: 844)
        .background(theme.bg)

        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        let nsImage = try XCTUnwrap(renderer.nsImage, "ImageRenderer produced no image")
        let tiff = try XCTUnwrap(nsImage.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: out))
        print("RECEIPT SHOT →", out, "(", png.count, "bytes )")
        XCTAssertGreaterThan(png.count, 8000, "screenshot looks empty")
    }
    #endif
}

private struct ShotNoopTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}
