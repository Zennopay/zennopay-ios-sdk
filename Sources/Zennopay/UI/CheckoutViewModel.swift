#if canImport(SwiftUI)
import SwiftUI
import Combine

/// Drives the native checkout flow: owns the state machine, calls the REST
/// client, persists the idempotency key before confirm, and delivers the final
/// `PaymentResult` exactly once — when the user closes the sheet (no
/// auto-dismiss on terminal states; the receipt/failure screens wait for Done).
///
/// `@MainActor` because it is bound to SwiftUI views; all REST work is awaited
/// off the actor-isolated `RESTClient`.
@available(iOS 13.0, macOS 13.0, *)
@MainActor
final class CheckoutViewModel: ObservableObject {

    // MARK: Published UI state

    @Published private(set) var state: CheckoutState = .scanning
    @Published private(set) var cameraAuthorization: CameraAuthorization = .notDetermined
    /// Non-nil while a recoverable error banner should show (e.g. scan
    /// rejected). Distinct from a terminal `.finished(.failed(...))`.
    @Published private(set) var transientError: ZennopayError?
    /// User-entered "Purpose of payment (optional)". Client-side only: echoed
    /// on the receipt; NOT transmitted to the backend (no field exists yet).
    @Published var purposeText: String = ""

    /// Resolved palette (partner appearance or `.automatic`). Screens read
    /// colors + radii from here.
    let theme: ZTheme

    /// Corridor from the session JWT's `zennopay:corridor` claim (e.g.
    /// "vn_vietqr"), refined by a QR-payload hint once one is scanned. Drives
    /// the scanner branding row and merchant-card captions.
    @Published private(set) var corridor: String?

    /// Display-only beneficiary facts peeked from the raw QR (bank + account).
    private(set) var qrPeek: QRPayload.Peek?

    /// True while the in-flight `/scan` came from the static-QR keypad (drives
    /// which screen hosts the "Checking…" state: keypad loading vs scanner).
    private(set) var validatingFromKeypad = false

    /// True once `/confirm` was accepted (or replayed) — the wallet debit may
    /// have happened, so failure/pending copy must carry the refund
    /// reassurance line.
    private(set) var walletDebited = false
    /// When the confirm was accepted (drives the receipt timestamp fallback).
    private(set) var confirmedAt: Date?

    // MARK: Dependencies

    let intentID: String
    private let config: ZennopayConfig
    private let client: RESTClient
    private let store: IdempotencyStore
    private let onResult: (PaymentResult) -> Void

    /// The last quote we displayed, retained so the terminal receipt can show
    /// the merchant + local amount even when the terminal `GET /:id` projection
    /// is the minimal `{id,status,amount_usd_cents,corridor}` shape.
    private(set) var lastQuote: CheckoutState.Quote?

    /// The richest terminal snapshot we have — the `/confirm` response (which
    /// carries merchant + txn id) or the terminal poll snapshot. Drives the
    /// success receipt.
    @Published private(set) var receiptSnapshot: IntentSnapshot?

    /// Guards single-fire confirm under rapid touch: once true, further slide
    /// completions are ignored.
    private var confirmStarted = false
    /// Guards single delivery of the final result to the host.
    private var resultDelivered = false

    init(
        intentID: String,
        config: ZennopayConfig,
        client: RESTClient,
        store: IdempotencyStore,
        theme: ZTheme = .automatic,
        corridor: String? = nil,
        onResult: @escaping (PaymentResult) -> Void
    ) {
        self.intentID = intentID
        self.config = config
        self.client = client
        self.store = store
        self.theme = theme
        self.corridor = corridor
        self.onResult = onResult
    }

    #if DEBUG
    /// DEBUG-ONLY (ZennopayDebugGallery): when true the VM is frozen for
    /// static rendering — `start()`, `confirm()`, and every network path are
    /// no-ops, so gallery screens can never touch the backend or move money.
    var debugFrozen = false

    /// DEBUG-ONLY: inject a fully-formed screen state for gallery rendering.
    func debugApply(
        state: CheckoutState,
        quote: CheckoutState.Quote? = nil,
        snapshot: IntentSnapshot? = nil,
        peek: QRPayload.Peek? = nil,
        corridor: String? = nil,
        purpose: String = "",
        walletDebited: Bool = false,
        confirmedAt: Date? = nil
    ) {
        debugFrozen = true
        if let quote { lastQuote = quote }
        if let snapshot { receiptSnapshot = snapshot }
        if let peek { qrPeek = peek }
        if let corridor { self.corridor = corridor }
        purposeText = purpose
        self.walletDebited = walletDebited
        self.confirmedAt = confirmedAt
        self.state = state
    }
    #endif

    /// True when the VM must not run lifecycle/network side effects (gallery).
    private var isFrozen: Bool {
        #if DEBUG
        return debugFrozen
        #else
        return false
        #endif
    }

    // MARK: - Lifecycle

    /// Called when the sheet appears. Recovers an interrupted confirm (process
    /// death mid-confirm) by re-reading status; otherwise asks for camera.
    func start() async {
        guard !isFrozen else { return }
        // Relaunch recovery: if we already persisted a confirm for this intent,
        // the money call may have gone through before we were killed. Re-read
        // status rather than re-scanning.
        if store.record(for: intentID) != nil {
            walletDebited = true
            await recoverViaStatus()
            return
        }
        cameraAuthorization = await CameraPermission.request()
    }

    /// Re-request permission after the user was sent to Settings.
    func refreshCameraAuthorization() {
        cameraAuthorization = CameraPermission.current
    }

    // MARK: - Scan

    /// Handle a raw QR string (from the live scanner, gallery decode, or the
    /// paste sheet). A STATIC QR (no embedded amount, peeked locally) routes to
    /// the amount keypad first; the backend re-parses authoritatively on scan.
    func submitScannedCode(_ raw: String) async {
        guard !isFrozen else { return }
        guard case .scanning = state else { return }
        let payload: String
        do {
            payload = try QRPayload.validate(raw)
        } catch {
            transientError = .invalidQRCode
            return
        }
        transientError = nil
        let peek = QRPayload.peek(payload)
        qrPeek = peek
        if let hint = QRPayload.corridorHint(payload) {
            corridor = hint
        }
        if peek.isStatic {
            transition(.staticQRCaptured(rawPayload: payload))
            return
        }
        validatingFromKeypad = false
        transition(.qrCaptured)
        await runScan(payload: payload, localAmountMinorUnits: nil)
    }

    /// Keypad "Review" for a static QR: scan with the user-entered local
    /// amount (minor units) to obtain the bound quote.
    func submitStaticAmount(minorUnits: Int) async {
        guard !isFrozen else { return }
        guard case .amountEntry(let raw) = state, minorUnits > 0 else { return }
        transientError = nil
        validatingFromKeypad = true
        transition(.qrCaptured)
        await runScan(payload: raw, localAmountMinorUnits: minorUnits)
    }

    private func runScan(payload: String, localAmountMinorUnits: Int?) async {
        do {
            let response = try await client.scan(
                qrPayload: payload, localAmountMinorUnits: localAmountMinorUnits
            )
            let quote = CheckoutState.Quote(from: response, defaultTTL: config.defaultQuoteTTL)
            lastQuote = quote
            transition(.scanValidated(quote))
        } catch let error as ZennopayError {
            transientError = error
            transition(.scanRejected)
        } catch {
            transientError = .networkError(underlying: String(describing: error))
            transition(.scanRejected)
        }
    }

    /// Silent quote refresh when the quote's validity window lapses. Re-runs
    /// `/scan` with the same payload — allowed (D2=B: scan doesn't burn the
    /// jti). Requires the raw payload be retained.
    func refreshQuote(rawPayload: String) async {
        guard !isFrozen else { return }
        guard case .quoted = state, !confirmStarted else { return }
        do {
            let response = try await client.scan(qrPayload: rawPayload)
            let quote = CheckoutState.Quote(from: response, defaultTTL: config.defaultQuoteTTL)
            lastQuote = quote
            state = .quoted(quote)
        } catch {
            // Non-fatal: keep showing the stale quote with an expiry warning;
            // the confirm path will re-validate server-side.
            transientError = .quoteExpired
        }
    }

    // MARK: - Confirm

    /// Fired by the slide-to-pay gesture. Single-fire.
    func confirm() async {
        guard !isFrozen else { return }
        guard case .quoted(let quote) = state, !confirmStarted else { return }
        confirmStarted = true
        transition(.userConfirmed)

        // D5=A: persist {intent_id, idempotency_key} to disk BEFORE the call.
        let record = store.persistIfNeeded(intentID: intentID)

        do {
            let snapshot = try await client.confirm(
                quoteID: quote.quoteID,
                quoteVersion: quote.quoteVersion,
                idempotencyKey: record.idempotencyKey
            )
            // Retain the rich confirm snapshot (merchant + txn id) for the
            // receipt; the terminal GET projection is minimal.
            receiptSnapshot = snapshot
            walletDebited = true
            confirmedAt = Date()
            transition(.confirmAccepted)
            await pollForResult()
        } catch let error as ZennopayError {
            // A replayed confirm means the money call already happened on a
            // prior attempt — recover the real status instead of failing.
            if error == .confirmReplay {
                walletDebited = true
                confirmedAt = confirmedAt ?? Date()
                transition(.confirmAccepted)
                await pollForResult()
            } else {
                finish(.failed(intentID: intentID, error: error))
            }
        } catch {
            finish(.failed(intentID: intentID, error: .networkError(underlying: String(describing: error))))
        }
    }

    // MARK: - Result

    private func pollForResult() async {
        do {
            let snapshot = try await client.pollUntilTerminal()
            // Merge: keep the richer confirm snapshot's merchant/txn fields if
            // the terminal projection is the minimal status shape.
            receiptSnapshot = mergeReceipt(terminal: snapshot, prior: receiptSnapshot)
            let status = IntentStatus(rawValue: snapshot.status) ?? .failed
            finish(PaymentResult.from(status: status, intentID: intentID))
        } catch let error as ZennopayError {
            // The confirm went through; an unresolved poll is PENDING, not a
            // failure — the backend auto-refunds an unsettled debit.
            if error == .timedOut || walletDebited {
                finish(.pending(intentID: intentID))
            } else {
                finish(.failed(intentID: intentID, error: error))
            }
        } catch {
            finish(.pending(intentID: intentID))
        }
    }

    /// Recover terminal status after a relaunch that found a persisted confirm.
    private func recoverViaStatus() async {
        state = .awaitingResult
        await pollForResult()
    }

    /// Retry after a failed result (result screen "Try again"). Reuses the same
    /// idempotency key so the backend dedupes.
    func retry() async {
        guard !isFrozen else { return }
        guard case .finished(.failed) = state, !resultDelivered else { return }
        confirmStarted = false
        state = .quoted(currentQuoteOrPlaceholder())
        await confirm()
    }

    /// Re-scan from the failure screen ("Try again" when no quote survived, or
    /// an explicit re-scan affordance).
    func reScan() {
        guard case .finished(.failed) = state, !resultDelivered else { return }
        confirmStarted = false
        transientError = nil
        state = .scanning
    }

    /// Back from the static-QR keypad to the scanner.
    func reScanFromKeypad() {
        transientError = nil
        transition(.reScan)
    }

    // MARK: - Sheet close paths (single host delivery)

    /// User dismissed the flow before any terminal state. No money moved.
    func cancel() {
        switch state {
        case .finished(let result):
            // X on a result screen behaves like Done.
            deliverToHost(result)
        case .confirming, .awaitingResult:
            leaveWhileProcessing()
        default:
            deliverToHost(.canceled(intentID: intentID))
        }
    }

    /// "Done" on the processing screen: the user leaves while the payment is
    /// still processing. Delivers `.pending`; the backend keeps working and the
    /// host reconciles via webhook / status read.
    func leaveWhileProcessing() {
        deliverToHost(.pending(intentID: intentID))
    }

    /// "Done" on a terminal result screen (receipt / failure / pending
    /// detail): deliver the finished result and let the host dismiss.
    func closeFromResult() {
        guard case .finished(let result) = state else { return }
        deliverToHost(result)
    }

    // MARK: - Helpers

    /// Reach a terminal state IN-SHEET. The result is NOT delivered to the host
    /// yet — the receipt/failure screen stays up until the user taps Done
    /// (`closeFromResult`). No auto-dismiss.
    private func finish(_ result: PaymentResult) {
        state = .finished(result)
        // Completed-and-terminal → the store record is no longer needed.
        if case .completed = result { store.clear(intentID: intentID) }
        if case .failed = result { /* keep record so a retry reuses the key */ }
        if case .canceled = result { store.clear(intentID: intentID) }
    }

    private func deliverToHost(_ result: PaymentResult) {
        guard !resultDelivered else { return }
        resultDelivered = true
        if case .canceled = result { store.clear(intentID: intentID) }
        onResult(result)
    }

    private func transition(_ event: CheckoutTransition.Event) {
        guard var next = CheckoutTransition.next(from: state, on: event) else { return }
        // The state machine emits a placeholder intentID for cancel; fill it.
        if case .finished(.canceled) = next {
            next = .finished(.canceled(intentID: intentID))
        }
        state = next
    }

    /// Prefer the terminal snapshot's status, but keep the richer confirm
    /// snapshot's merchant/txn/amount fields when the terminal read omitted them.
    private func mergeReceipt(terminal: IntentSnapshot, prior: IntentSnapshot?) -> IntentSnapshot {
        guard let prior else { return terminal }
        return IntentSnapshot(
            id: terminal.id,
            status: terminal.status,
            amount_usd_cents: terminal.amount_usd_cents != 0 ? terminal.amount_usd_cents : prior.amount_usd_cents,
            corridor: terminal.corridor ?? prior.corridor,
            merchant: terminal.merchant ?? prior.merchant,
            qr_kind: terminal.qr_kind ?? prior.qr_kind,
            quote_id: terminal.quote_id ?? prior.quote_id,
            quote_version: terminal.quote_version ?? prior.quote_version,
            quote_local_amount_minor_units: terminal.quote_local_amount_minor_units ?? prior.quote_local_amount_minor_units,
            quote_local_currency: terminal.quote_local_currency ?? prior.quote_local_currency,
            quote_expires_at: terminal.quote_expires_at ?? prior.quote_expires_at,
            confirm_state: terminal.confirm_state ?? prior.confirm_state,
            beneficiary: terminal.beneficiary ?? prior.beneficiary,
            transaction_id: terminal.transaction_id ?? prior.transaction_id,
            created_at: terminal.created_at ?? prior.created_at,
            updated_at: terminal.updated_at ?? prior.updated_at
        )
    }

    // MARK: - Receipt assembly

    /// Merchant display name with a corridor-aware fallback: a personal /
    /// bank-account VietQR carries no merchant-name tag.
    var displayMerchantName: String {
        if let name = lastQuote?.merchantName, !name.isEmpty { return name }
        if let name = receiptSnapshot?.merchant?.name, !name.isEmpty { return name }
        if let name = receiptSnapshot?.beneficiary?.merchant_name, !name.isEmpty { return name }
        if let entry = CorridorBranding.entry(for: corridor) {
            return "\(entry.countryName) Merchant"
        }
        return "Recipient"
    }

    /// The receipt shown on the success/pending screens, assembled from the
    /// last quote (merchant + local amount), the QR peek (bank + account), and
    /// the terminal snapshot (USD + txn id + corridor).
    var receipt: Receipt? {
        guard lastQuote != nil || receiptSnapshot != nil else { return nil }
        let snap = receiptSnapshot
        let localMinor = snap?.quote_local_amount_minor_units ?? lastQuote?.localAmountMinorUnits
        let localCurrency = snap?.quote_local_currency
            ?? snap?.merchant?.currency_numeric
            ?? lastQuote?.localCurrency
        let usdCents = (snap?.amount_usd_cents).flatMap { $0 != 0 ? $0 : nil }
            ?? lastQuote?.amountUSDCents ?? 0
        let timestamp = (snap?.updated_at).flatMap(Self.parseISO8601) ?? confirmedAt ?? Date()
        return Receipt(
            merchantName: displayMerchantName,
            localMinorUnits: localMinor,
            localCurrency: localCurrency,
            usdCents: usdCents,
            transactionID: snap?.transaction_id,
            intentID: intentID,
            bankName: qrPeek?.bankName,
            accountMasked: qrPeek?.accountMasked,
            purpose: purposeText.trimmingCharacters(in: .whitespacesAndNewlines),
            timestamp: timestamp,
            corridor: snap?.corridor ?? corridor
        )
    }

    /// Display model for the terminal receipt / pending-detail screens.
    struct Receipt: Equatable {
        let merchantName: String
        let localMinorUnits: Int?
        let localCurrency: String?
        let usdCents: Int
        let transactionID: String?
        let intentID: String
        let bankName: String?
        let accountMasked: String?
        let purpose: String
        let timestamp: Date
        let corridor: String?
    }

    static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private func currentQuoteOrPlaceholder() -> CheckoutState.Quote {
        if let lastQuote { return lastQuote }
        // Placeholder used only during a retry transition; the real quote is
        // still on the confirm path server-side. quote_id/version are empty
        // here — retry only runs after a `.quoted` state existed, so the live
        // quote is normally still retained.
        return CheckoutState.Quote(
            from: ScanResponse(
                intent_id: intentID,
                status: "created",
                merchant: ScanResponse.Merchant(
                    scheme: "", name: "", city: nil, country: nil, mcc: nil
                ),
                qr_kind: "dynamic",
                quote: ScanResponse.Quote(
                    quote_id: "", quote_version: 0,
                    amount_usd_cents: 0, local_amount_minor_units: 0,
                    local_currency: "", expires_at: 0
                )
            ),
            defaultTTL: config.defaultQuoteTTL
        )
    }
}
#endif
