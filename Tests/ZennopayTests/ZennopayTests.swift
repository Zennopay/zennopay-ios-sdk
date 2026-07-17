import XCTest
@testable import Zennopay

// MARK: - JWT claim validation + intent binding

final class JWTClaimsTests: XCTestCase {

    func test_succeeds_whenIntentMatchesAndNotExpired() throws {
        let jwt = makeJWT(claims: validClaims(intent: "zp_abc123"))
        let decoded = try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        XCTAssertEqual(decoded.intentID, "zp_abc123")
        XCTAssertEqual(decoded.audience, "zennopay-checkout")
        XCTAssertEqual(decoded.jti, "jti-1")
    }

    func test_throwsIntentMismatch_whenClaimDiffers() {
        let jwt = makeJWT(claims: validClaims(intent: "zp_OTHER"))
        XCTAssertThrowsError(try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")) {
            XCTAssertEqual($0 as? ZennopayError, .intentMismatch)
        }
    }

    func test_throwsExpired_whenPastSkew() {
        var c = validClaims(intent: "zp_abc123")
        c["exp"] = Int(Date().addingTimeInterval(-300).timeIntervalSince1970)
        XCTAssertThrowsError(try JWTClaims.validate(jwt: makeJWT(claims: c), expectedIntentID: "zp_abc123")) {
            XCTAssertEqual($0 as? ZennopayError, .jwtExpired)
        }
    }

    func test_acceptsToken_withinClockSkew() throws {
        var c = validClaims(intent: "zp_abc123")
        c["exp"] = Int(Date().addingTimeInterval(-10).timeIntervalSince1970)
        XCTAssertNoThrow(try JWTClaims.validate(jwt: makeJWT(claims: c), expectedIntentID: "zp_abc123"))
    }

    func test_throwsMalformed_onWrongSegmentCount() {
        XCTAssertThrowsError(try JWTClaims.validate(jwt: "a.b", expectedIntentID: "zp")) {
            XCTAssertEqual($0 as? ZennopayError, .malformedToken)
        }
    }

    func test_throwsMalformed_onNonBase64Payload() {
        XCTAssertThrowsError(try JWTClaims.validate(jwt: "h.!!!.s", expectedIntentID: "zp")) {
            XCTAssertEqual($0 as? ZennopayError, .malformedToken)
        }
    }

    func test_throwsMissingClaim_whenAudienceAbsent() {
        var c = validClaims(intent: "zp_abc123")
        c.removeValue(forKey: "aud")
        XCTAssertThrowsError(try JWTClaims.validate(jwt: makeJWT(claims: c), expectedIntentID: "zp_abc123")) {
            XCTAssertEqual($0 as? ZennopayError, .jwtMissingClaim)
        }
    }

    func test_throwsMissingClaim_whenJtiAbsent() {
        var c = validClaims(intent: "zp_abc123")
        c.removeValue(forKey: "jti")
        XCTAssertThrowsError(try JWTClaims.validate(jwt: makeJWT(claims: c), expectedIntentID: "zp_abc123")) {
            XCTAssertEqual($0 as? ZennopayError, .jwtMissingClaim)
        }
    }

    func test_decodesCorridorClaim_whenPresent() throws {
        var c = validClaims(intent: "zp_abc123")
        c["zennopay:corridor"] = "vn_vietqr"
        let decoded = try JWTClaims.validate(jwt: makeJWT(claims: c), expectedIntentID: "zp_abc123")
        XCTAssertEqual(decoded.corridor, "vn_vietqr")
    }

    func test_corridorClaim_isOptional() throws {
        let decoded = try JWTClaims.validate(
            jwt: makeJWT(claims: validClaims(intent: "zp_abc123")), expectedIntentID: "zp_abc123"
        )
        XCTAssertNil(decoded.corridor)
    }
}

// MARK: - QR payload handling

final class QRPayloadTests: XCTestCase {

    func test_looksLikeEMVCo_true_forPromptPayPrefix() {
        XCTAssertTrue(QRPayload.looksLikeEMVCo("000201021129370016A000000677010111"))
    }

    func test_looksLikeEMVCo_false_forEmptyOrNonPrefixed() {
        XCTAssertFalse(QRPayload.looksLikeEMVCo(""))
        XCTAssertFalse(QRPayload.looksLikeEMVCo("hello world"))
    }

    func test_validate_trimsAndReturnsPayload() throws {
        let out = try QRPayload.validate("  000201somepayload  ")
        XCTAssertEqual(out, "000201somepayload")
    }

    func test_validate_throwsOnEmpty() {
        XCTAssertThrowsError(try QRPayload.validate("   ")) {
            XCTAssertEqual($0 as? ZennopayError, .invalidQRCode)
        }
    }

    func test_validate_throwsOnTooLong() {
        let long = String(repeating: "0", count: QRPayload.maxLength + 1)
        XCTAssertThrowsError(try QRPayload.validate(long)) {
            XCTAssertEqual($0 as? ZennopayError, .invalidQRCode)
        }
    }

    func test_validate_throwsOnNonAlphanumeric() {
        XCTAssertThrowsError(try QRPayload.validate("!!! @@@ ###")) {
            XCTAssertEqual($0 as? ZennopayError, .invalidQRCode)
        }
    }

    func test_corridorHint_detectsPromptPayAndVietQR() {
        XCTAssertEqual(QRPayload.corridorHint("xxxA000000677xxx"), "th_promptpay")
        XCTAssertEqual(QRPayload.corridorHint("xxxA000000727xxx"), "vn_vietqr")
        XCTAssertNil(QRPayload.corridorHint("000201nothing"))
    }

    // MARK: display-only EMVCo peek (D4=A: never trusted for money movement)

    /// The demo VietQR: dynamic (tag 54 present), Vietcombank BIN + account.
    private let dynamicVietQR =
        "00020101021238570010A00000072701270006970436011310230203300000208QRIBFTTA5303704540735000005802VN630449D2"

    func test_peek_dynamicVietQR_extractsBankAndAccount() {
        let peek = QRPayload.peek(dynamicVietQR)
        XCTAssertFalse(peek.isStatic)
        XCTAssertEqual(peek.bankBIN, "970436")
        XCTAssertEqual(peek.accountNumber, "1023020330000")
        XCTAssertEqual(peek.bankName, "VIETCOMBANK")
        XCTAssertEqual(peek.accountMasked, "10230…0000")
    }

    func test_peek_staticQR_flagsAmountEntry() {
        // Same QR minus tag 54 (no embedded amount) → static.
        let staticQR =
            "00020101021138570010A00000072701270006970436011310230203300000208QRIBFTTA53037045802VN63041234"
        let peek = QRPayload.peek(staticQR)
        XCTAssertTrue(peek.isStatic)
        XCTAssertEqual(peek.bankBIN, "970436")
    }

    func test_peek_garbage_fallsThroughAsDynamic() {
        // A malformed TLV must NOT gate the flow — fall through to the
        // authoritative backend scan (isStatic false, nothing peeked).
        let peek = QRPayload.peek("hello world not a qr")
        XCTAssertFalse(peek.isStatic)
        XCTAssertNil(peek.bankBIN)
        XCTAssertNil(peek.accountNumber)
    }

    func test_parseTLV_tokenizesTopLevelFields() {
        let fields = QRPayload.parseTLV(dynamicVietQR)
        XCTAssertEqual(fields?["54"], "3500000")
        XCTAssertEqual(fields?["53"], "704")
        XCTAssertEqual(fields?["58"], "VN")
    }
}

// MARK: - Currency formatting (LOCAL primary / USD chip)

final class CurrencyDisplayTests: XCTestCase {

    func test_symbols_labels_flags() {
        XCTAssertEqual(CurrencyDisplay.symbol(forNumeric: "704"), "₫")
        XCTAssertEqual(CurrencyDisplay.symbol(forNumeric: "764"), "฿")
        XCTAssertEqual(CurrencyDisplay.symbol(forNumeric: "840"), "$")
        XCTAssertEqual(CurrencyDisplay.label(forNumeric: "704"), "VND")
        XCTAssertEqual(CurrencyDisplay.flag(forNumeric: "704"), "🇻🇳")
        XCTAssertEqual(CurrencyDisplay.flag(forNumeric: "764"), "🇹🇭")
        XCTAssertEqual(CurrencyDisplay.flag(forNumeric: "840"), "🇺🇸")
    }

    func test_formatMinor_vnd_hasThousandsSeparators_noDecimals() {
        // ₫3,500,000 — the demo quote (backend minor units are hundredths).
        XCTAssertEqual(CurrencyDisplay.formatMinor(350_000_000, numeric: "704"), "₫3,500,000")
        XCTAssertEqual(CurrencyDisplay.formatMinor(100_000, numeric: "704"), "₫1,000")
    }

    func test_formatMinor_thb_twoDecimalPlaces() {
        XCTAssertEqual(CurrencyDisplay.formatMinor(11_000, numeric: "764"), "฿110.00")
        XCTAssertEqual(CurrencyDisplay.formatMinor(123_456_789, numeric: "764"), "฿1,234,567.89")
    }

    func test_formatMinorWithLabel_receiptHero() {
        XCTAssertEqual(CurrencyDisplay.formatMinorWithLabel(350_000_000, numeric: "704"), "3,500,000 VND")
    }

    func test_formatUSDCents_groupedTwoPlaces() {
        XCTAssertEqual(CurrencyDisplay.formatUSDCents(14000), "$140.00")
        XCTAssertEqual(CurrencyDisplay.formatUSDCents(5), "$0.05")
        XCTAssertEqual(CurrencyDisplay.formatUSDCents(123_456_789), "$1,234,567.89")
    }

    func test_exchangeRateLine_impliedFromQuote() {
        XCTAssertEqual(
            CurrencyDisplay.exchangeRateLine(usdCents: 14000, localMinorUnits: 350_000_000, localCurrency: "704"),
            "1 USD = 25,000.00 VND"
        )
        XCTAssertNil(CurrencyDisplay.exchangeRateLine(usdCents: 0, localMinorUnits: 100, localCurrency: "704"))
        XCTAssertNil(CurrencyDisplay.exchangeRateLine(usdCents: 100, localMinorUnits: nil, localCurrency: "704"))
    }

    func test_disbursementLimit_vndPerTransaction() {
        // ₫3.5M (the demo) is inside the ₫5M cap; ₫5M + 1 minor unit is over.
        XCTAssertFalse(DisbursementLimit.exceedsVNDPerTransaction(minorUnits: 350_000_000, currencyNumeric: "704"))
        XCTAssertTrue(DisbursementLimit.exceedsVNDPerTransaction(minorUnits: 500_000_001, currencyNumeric: "704"))
        // Cap applies to VND only.
        XCTAssertFalse(DisbursementLimit.exceedsVNDPerTransaction(minorUnits: 600_000_000, currencyNumeric: "764"))
    }
}

// MARK: - Corridor branding registry

final class CorridorBrandingTests: XCTestCase {

    func test_vietnam_entry() {
        let entry = CorridorBranding.entry(for: "vn_vietqr")
        XCTAssertEqual(entry?.countryName, "Vietnam")
        XCTAssertEqual(entry?.schemeName, "VietQR")
        XCTAssertEqual(entry?.chips.map(\.id), ["vietqr", "momo", "zalopay", "napas"])
    }

    func test_thailand_entry() {
        let entry = CorridorBranding.entry(for: "th_promptpay")
        XCTAssertEqual(entry?.countryName, "Thailand")
        XCTAssertEqual(entry?.chips.map(\.id), ["promptpay", "truemoney"])
    }

    func test_lookup_isCaseInsensitive_andNilForUnknown() {
        XCTAssertNotNil(CorridorBranding.entry(for: "VN_VIETQR"))
        XCTAssertNil(CorridorBranding.entry(for: "xx_unknown"))
        XCTAssertNil(CorridorBranding.entry(for: nil))
        XCTAssertNil(CorridorBranding.entry(for: ""))
    }

    func test_register_extendsTheRegistry() {
        let ph = CorridorBranding.Entry(
            corridor: "ph_qrph", countryName: "Philippines", schemeName: "QR Ph",
            chips: [CorridorBranding.SchemeChip(
                id: "qrph", segments: [CorridorBranding.Segment(text: "QRPh", rgb: 0x0033A0)]
            )],
            supportedQRHelp: "Philippine QR Ph merchant codes."
        )
        CorridorBranding.register(ph)
        defer { /* registry is process-global; harmless for other tests */ }
        XCTAssertEqual(CorridorBranding.entry(for: "ph_qrph")?.countryName, "Philippines")
    }
}

// MARK: - Radius guardrail (appearance clamp)

final class RadiusGuardTests: XCTestCase {

    func test_clamp_capsAtTwelve_andFloorsAtZero() {
        XCTAssertEqual(RadiusGuard.clamp(14), 12)
        XCTAssertEqual(RadiusGuard.clamp(12), 12)
        XCTAssertEqual(RadiusGuard.clamp(8), 8)
        XCTAssertEqual(RadiusGuard.clamp(-2), 0)
    }
}

#if canImport(UIKit)
// MARK: - Partner appearance (UIKit-only surface)

final class AppearanceTests: XCTestCase {

    func test_defaultAppearance_matchesDesignTokens() {
        let a = ZennopayAppearance.default
        XCTAssertEqual(a.cornerRadius.input, 4)
        XCTAssertEqual(a.cornerRadius.card, 8)
        XCTAssertEqual(a.cornerRadius.slide, 12)
        XCTAssertEqual(a.primaryButton.cornerRadius, 8)
        XCTAssertEqual(a.font.family, "General Sans")
        XCTAssertNil(a.logo)
    }

    func test_automatic_and_default_areSameShape() {
        XCTAssertEqual(ZennopayAppearance.automatic.cornerRadius.card,
                       ZennopayAppearance.default.cornerRadius.card)
    }

    func test_cornerRadius_clampedOnInit() {
        let r = ZennopayAppearance.CornerRadius(input: 30, card: 25, slide: 99)
        XCTAssertEqual(r.input, 12)
        XCTAssertEqual(r.card, 12)
        XCTAssertEqual(r.slide, 12)
    }

    func test_primaryButton_radiusClamped() {
        let b = ZennopayAppearance.PrimaryButton(cornerRadius: 14)
        XCTAssertEqual(b.cornerRadius, 12, "14pt requests clamp to the DESIGN.md 12px cap")
    }
}
#endif

// MARK: - State machine transitions

final class CheckoutStateTests: XCTestCase {

    // Fixed expiry so equality checks are deterministic (no per-access Date()).
    private let quote = CheckoutState.Quote(
        from: sampleScanResponse(), defaultTTL: 30, now: Date(timeIntervalSince1970: 1_700_000_000)
    )

    func test_happyPath_transitions() {
        var s: CheckoutState = .scanning
        s = CheckoutTransition.next(from: s, on: .qrCaptured)!
        XCTAssertEqual(s, .validatingScan)
        s = CheckoutTransition.next(from: s, on: .scanValidated(quote))!
        XCTAssertEqual(s, .quoted(quote))
        s = CheckoutTransition.next(from: s, on: .userConfirmed)!
        XCTAssertEqual(s, .confirming)
        s = CheckoutTransition.next(from: s, on: .confirmAccepted)!
        XCTAssertEqual(s, .awaitingResult)
        s = CheckoutTransition.next(from: s, on: .terminal(.completed(intentID: "zp")))!
        XCTAssertEqual(s, .finished(.completed(intentID: "zp")))
    }

    func test_scanRejected_returnsToScanning() {
        let s = CheckoutTransition.next(from: .validatingScan, on: .scanRejected)
        XCTAssertEqual(s, .scanning)
    }

    func test_reScan_fromQuoted_returnsToScanning() {
        let s = CheckoutTransition.next(from: .quoted(quote), on: .reScan)
        XCTAssertEqual(s, .scanning)
    }

    func test_cancel_fromAnyNonTerminal_finishesCanceled() {
        let s = CheckoutTransition.next(from: .quoted(quote), on: .cancel)
        if case .finished(.canceled) = s {} else { XCTFail("expected finished canceled, got \(String(describing: s))") }
    }

    func test_illegalTransition_returnsNil() {
        // Can't confirm from scanning.
        XCTAssertNil(CheckoutTransition.next(from: .scanning, on: .userConfirmed))
        // Can't cancel a finished flow.
        XCTAssertNil(CheckoutTransition.next(from: .finished(.completed(intentID: "zp")), on: .cancel))
    }

    func test_staticQR_routesThroughAmountEntry() {
        // Static QR: scanning → amountEntry (keypad) → validatingScan.
        var s = CheckoutTransition.next(from: .scanning, on: .staticQRCaptured(rawPayload: "000201raw"))
        XCTAssertEqual(s, .amountEntry(rawPayload: "000201raw"))
        s = CheckoutTransition.next(from: s!, on: .qrCaptured)
        XCTAssertEqual(s, .validatingScan)
    }

    func test_amountEntry_backToScanner() {
        let s = CheckoutTransition.next(from: .amountEntry(rawPayload: "x"), on: .reScan)
        XCTAssertEqual(s, .scanning)
    }

    func test_amountEntry_cancelFinishesCanceled() {
        let s = CheckoutTransition.next(from: .amountEntry(rawPayload: "x"), on: .cancel)
        if case .finished(.canceled) = s {} else { XCTFail("expected canceled, got \(String(describing: s))") }
    }

    func test_quoteExpiry_computedFromExpiresAt() {
        let now = Date()
        // expires_at is epoch millis; set it 1s in the past.
        let pastMillis = Int((now.addingTimeInterval(-1)).timeIntervalSince1970 * 1000)
        let r = ScanResponse(
            intent_id: "zp",
            status: "created",
            merchant: sampleScanResponse().merchant,
            qr_kind: "dynamic",
            quote: ScanResponse.Quote(
                quote_id: "q1", quote_version: 1,
                amount_usd_cents: 500, local_amount_minor_units: 100,
                local_currency: "764", expires_at: pastMillis
            )
        )
        let q = CheckoutState.Quote(from: r, defaultTTL: 30, now: now)
        XCTAssertTrue(q.isExpired(now: now))
    }
}

// MARK: - Idempotency-key persistence

final class IdempotencyStoreTests: XCTestCase {

    private func tempStore() -> (IdempotencyStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zp-test-\(UUID().uuidString)", isDirectory: true)
        return (IdempotencyStore(directory: dir), dir)
    }

    func test_persistIfNeeded_returnsSameKey_onRepeat() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = store.persistIfNeeded(intentID: "zp_1")
        let second = store.persistIfNeeded(intentID: "zp_1")
        XCTAssertEqual(first.idempotencyKey, second.idempotencyKey)
    }

    func test_record_survivesNewStoreInstance_relaunchRecovery() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let saved = store.persistIfNeeded(intentID: "zp_2", makeKey: { "fixed-key" })
        XCTAssertEqual(saved.idempotencyKey, "fixed-key")

        // Simulate relaunch: new store over the same directory.
        let reopened = IdempotencyStore(directory: dir)
        let recovered = reopened.record(for: "zp_2")
        XCTAssertEqual(recovered?.idempotencyKey, "fixed-key")
    }

    func test_clear_removesRecord() {
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = store.persistIfNeeded(intentID: "zp_3")
        store.clear(intentID: "zp_3")
        XCTAssertNil(store.record(for: "zp_3"))
    }

    func test_persistBeforeConfirm_keyStableAcrossRetries() {
        // The retry contract: reuse the same key so the backend dedupes.
        let (store, dir) = tempStore(); defer { try? FileManager.default.removeItem(at: dir) }
        let k1 = store.persistIfNeeded(intentID: "zp_4").idempotencyKey
        // A "retry" re-fetches the persisted record instead of minting a new key.
        let k2 = store.record(for: "zp_4")?.idempotencyKey
        XCTAssertEqual(k1, k2)
    }
}

// MARK: - Error taxonomy mapping

final class ErrorTaxonomyTests: XCTestCase {

    func test_401_onScan_mapsToSessionExpired() {
        XCTAssertEqual(ZennopayError.from(httpStatus: 401, code: "authentication_failed"), .sessionExpired)
    }

    func test_401_onConfirm_mapsToReplay() {
        // A 401 on confirm covers jwt.jti_replay / jwt.intent_invalid_state —
        // the money call already happened → recover via status poll.
        XCTAssertEqual(
            ZennopayError.from(httpStatus: 401, code: "authentication_failed", onConfirm: true),
            .confirmReplay
        )
    }

    func test_409_onConfirm_mapsToQuoteExpired_elseServerError() {
        // confirm.quote_expired / quote_mismatch / quote_superseded / not_scanned
        // all arrive as HTTP 409 `conflict` — the specific reason is not on the
        // wire, so they collapse to .quoteExpired (re-scan / re-quote).
        XCTAssertEqual(ZennopayError.from(httpStatus: 409, code: "conflict", onConfirm: true), .quoteExpired)
        XCTAssertEqual(
            ZennopayError.from(httpStatus: 409, code: "conflict", onConfirm: false),
            .serverError(status: 409, code: "conflict")
        )
    }

    func test_400and422_onScan_mapToInvalidQR() {
        XCTAssertEqual(ZennopayError.from(httpStatus: 400, code: "validation_failed"), .invalidQRCode)
        XCTAssertEqual(ZennopayError.from(httpStatus: 422, code: nil), .invalidQRCode)
    }

    func test_400_onConfirm_mapsToPaymentFailed() {
        // confirm.dynamic_amount_override / bad body.
        XCTAssertEqual(
            ZennopayError.from(httpStatus: 400, code: "validation_failed", onConfirm: true),
            .paymentFailed
        )
    }

    func test_unknownStatus_mapsToServerError() {
        XCTAssertEqual(
            ZennopayError.from(httpStatus: 500, code: "internal_error"),
            .serverError(status: 500, code: "internal_error")
        )
    }

    func test_paymentResultFromStatus_collapsesTerminalStates() {
        XCTAssertEqual(PaymentResult.from(status: .captured, intentID: "zp"), .completed(intentID: "zp"))
        XCTAssertEqual(PaymentResult.from(status: .failed, intentID: "zp"), .failed(intentID: "zp", error: .paymentFailed))
        XCTAssertEqual(PaymentResult.from(status: .expired, intentID: "zp"), .failed(intentID: "zp", error: .quoteExpired))
    }

    func test_nonTerminalStatus_collapsesToPending_notFailure() {
        // An unresolved poll (still created/authorized at the deadline) is a
        // PENDING outcome: the backend auto-refunds an unsettled debit.
        XCTAssertEqual(PaymentResult.from(status: .created, intentID: "zp"), .pending(intentID: "zp"))
        XCTAssertEqual(PaymentResult.from(status: .authorized, intentID: "zp"), .pending(intentID: "zp"))
    }

    func test_pendingResult_carriesIntentID() {
        XCTAssertEqual(PaymentResult.pending(intentID: "zp_9").intentID, "zp_9")
    }

    func test_intentStatus_isTerminal() {
        XCTAssertTrue(IntentStatus.captured.isTerminal)
        XCTAssertTrue(IntentStatus.failed.isTerminal)
        XCTAssertFalse(IntentStatus.created.isTerminal)
        XCTAssertFalse(IntentStatus.authorized.isTerminal)
    }
}

// MARK: - REST client (stub transport)

final class RESTClientTests: XCTestCase {

    private let config = ZennopayConfig(apiBaseURL: URL(string: "https://api.test.zennopay.com")!)

    func test_scan_sendsRawPayload_andDecodesQuote() async throws {
        let stub = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/payment_intents/zp_1/scan")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-1")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("000201rawqr"), "raw payload must be sent: \(body)")
            return (Self.scanJSON, 200)
        }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "tok-1",
                                refreshSession: nil, transport: stub)
        let resp = try await client.scan(qrPayload: "000201rawqr")
        XCTAssertEqual(resp.merchant.name, "Bangkok Coffee")
        XCTAssertEqual(resp.merchant.scheme, "promptpay")
        XCTAssertEqual(resp.qr_kind, "dynamic")
        XCTAssertEqual(resp.quote.amount_usd_cents, 320)
        XCTAssertEqual(resp.quote.quote_id, "q1")
        XCTAssertEqual(resp.quote.local_currency, "764")
    }

    func test_401_triggersRefresh_thenRetriesWithNewToken() async throws {
        let calls = Locked(0)
        let stub = StubTransport { request in
            let n = calls.mutate { $0 += 1; return $0 }
            if n == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale")
                return (Self.errorJSON("authentication_failed"), 401)
            } else {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
                return (Self.snapshotJSON, 200)
            }
        }
        let client = RESTClient(
            config: config, intentID: "zp_1", sessionJWT: "stale",
            refreshSession: { _ in "fresh" }, transport: stub
        )
        let snap = try await client.fetchStatus()
        XCTAssertEqual(snap.status, "captured")
        XCTAssertEqual(calls.value, 2)
    }

    func test_401_withNoRefreshHook_surfacesSessionExpired() async {
        let stub = StubTransport { _ in (Self.errorJSON("authentication_failed"), 401) }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "stale",
                                refreshSession: nil, transport: stub)
        do {
            _ = try await client.fetchStatus()
            XCTFail("expected throw")
        } catch let e as ZennopayError {
            XCTAssertEqual(e, .sessionExpired)
        } catch { XCTFail("wrong error type: \(error)") }
    }

    func test_confirm_sendsIdempotencyKeyAndQuoteBinding() async throws {
        let stub = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/payment_intents/zp_1/confirm")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-1")
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            XCTAssertTrue(body.contains("\"quote_id\":\"q1\""), "confirm body: \(body)")
            XCTAssertTrue(body.contains("\"quote_version\":2"), "confirm body: \(body)")
            return (Self.snapshotJSON, 200)
        }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "tok",
                                refreshSession: nil, transport: stub)
        let resp = try await client.confirm(quoteID: "q1", quoteVersion: 2, idempotencyKey: "idem-1")
        XCTAssertEqual(resp.status, "captured")
    }

    func test_confirm_401_replay_mapsToConfirmReplay() async {
        // A second confirm on the same jti → 401 jwt.jti_replay.
        let stub = StubTransport { _ in (Self.errorJSON("authentication_failed"), 401) }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "tok",
                                refreshSession: nil, transport: stub)
        do {
            _ = try await client.confirm(quoteID: "q1", quoteVersion: 1, idempotencyKey: "idem-1")
            XCTFail("expected throw")
        } catch let e as ZennopayError {
            XCTAssertEqual(e, .confirmReplay)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_confirm_409_quoteConflict_mapsToQuoteExpired() async {
        let stub = StubTransport { _ in (Self.errorJSON("conflict"), 409) }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "tok",
                                refreshSession: nil, transport: stub)
        do {
            _ = try await client.confirm(quoteID: "q1", quoteVersion: 1, idempotencyKey: "idem-1")
            XCTFail("expected throw")
        } catch let e as ZennopayError {
            XCTAssertEqual(e, .quoteExpired)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_pollUntilTerminal_stopsOnTerminalStatus() async throws {
        let calls = Locked(0)
        let stub = StubTransport { _ in
            let n = calls.mutate { $0 += 1; return $0 }
            let status = n < 2 ? "authorized" : "captured"
            return (Self.snapshotJSON(status: status), 200)
        }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "tok",
                                refreshSession: nil, transport: stub)
        let snap = try await client.pollUntilTerminal(sleep: { _ in })
        XCTAssertEqual(snap.status, "captured")
        XCTAssertGreaterThanOrEqual(calls.value, 2)
    }

    // MARK: fixtures
    static let scanJSON = """
    {"intent_id":"zp_1","status":"created",
     "merchant":{"scheme":"promptpay","name":"Bangkok Coffee","city":"Bangkok","country":"TH","mcc":"5411"},
     "qr_kind":"dynamic",
     "quote":{"quote_id":"q1","quote_version":1,"amount_usd_cents":320,
              "local_amount_minor_units":11000,"local_currency":"764","expires_at":1782908263794}}
    """.data(using: .utf8)!
    static let snapshotJSON = snapshotJSON(status: "captured")
    static func snapshotJSON(status: String) -> Data {
        "{\"id\":\"zp_1\",\"status\":\"\(status)\",\"amount_usd_cents\":320,\"corridor\":\"th_promptpay\"}"
            .data(using: .utf8)!
    }
    static func errorJSON(_ code: String) -> Data {
        "{\"error\":{\"code\":\"\(code)\",\"message\":\"x\",\"request_id\":\"r\"}}".data(using: .utf8)!
    }
}

// MARK: - Test doubles

/// A synchronous HTTP transport stub. The handler returns (body, statusCode).
struct StubTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) -> (Data, Int)
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let (data, status) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }
}

/// Minimal thread-safe box for asserting call counts across the stub closure.
final class Locked<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    @discardableResult
    func mutate<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&_value) }
}

// MARK: - Shared fixtures

func validClaims(intent: String) -> [String: Any] {
    [
        "zennopay:intent_id": intent,
        "exp": Int(Date().addingTimeInterval(300).timeIntervalSince1970),
        "iss": "partner-wallet.app",
        "aud": "zennopay-checkout",
        "jti": "jti-1",
    ]
}

func sampleScanResponse() -> ScanResponse {
    ScanResponse(
        intent_id: "zp_1",
        status: "created",
        merchant: ScanResponse.Merchant(
            scheme: "promptpay", name: "Bangkok Coffee", city: "Bangkok",
            country: "TH", mcc: "5411"
        ),
        qr_kind: "dynamic",
        quote: ScanResponse.Quote(
            quote_id: "q1", quote_version: 1,
            amount_usd_cents: 320, local_amount_minor_units: 11000,
            local_currency: "764", expires_at: 1782908263794
        )
    )
}

func makeJWT(claims: [String: Any]) -> String {
    let header = ["alg": "RS256", "typ": "JWT"]
    let headerData = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
    let payloadData = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    return "\(base64URLEncode(headerData)).\(base64URLEncode(payloadData)).sig"
}

func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
