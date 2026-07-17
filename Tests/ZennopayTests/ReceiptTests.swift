import XCTest
@testable import Zennopay

// MARK: - Receipt DTO decode (all statuses incl. refunded)

final class ReceiptDTOTests: XCTestCase {

    private func decode(_ json: String) throws -> ReceiptDTO {
        try JSONDecoder().decode(ReceiptDTO.self, from: Data(json.utf8))
    }

    /// The canonical captured receipt shape from the contract.
    private let capturedJSON = """
    {
      "intent_id": "zp_abc123",
      "status": "captured",
      "merchant": { "name": "Cà Phê Sài Gòn", "account_no": "•••• 0000", "bank_no": "970436", "country": "VN" },
      "amount_usd_cents": 14000,
      "local_amount_minor_units": 350000000,
      "local_currency": "704",
      "exchange_rate": 25000.0,
      "fees": { "margin_usd_cents": 210 },
      "corridor": "vn_vietqr",
      "transaction_ref": "9p_txn_000042",
      "created_at": "2026-07-18T04:07:11.000Z",
      "updated_at": "2026-07-18T04:07:41.000Z"
    }
    """

    func test_decode_captured_fullShape() throws {
        let r = try decode(capturedJSON)
        XCTAssertEqual(r.intent_id, "zp_abc123")
        XCTAssertEqual(r.status, "captured")
        XCTAssertEqual(r.receiptStatus, .captured)
        XCTAssertEqual(r.merchant?.name, "Cà Phê Sài Gòn")
        XCTAssertEqual(r.merchant?.account_no, "•••• 0000")
        XCTAssertEqual(r.merchant?.bank_no, "970436")
        XCTAssertEqual(r.merchant?.country, "VN")
        XCTAssertEqual(r.amount_usd_cents, 14000)
        XCTAssertEqual(r.local_amount_minor_units, 350000000)
        XCTAssertEqual(r.local_currency, "704")
        XCTAssertEqual(r.exchange_rate, 25000.0)
        XCTAssertEqual(r.fees?.margin_usd_cents, 210)
        XCTAssertEqual(r.corridor, "vn_vietqr")
        XCTAssertEqual(r.transaction_ref, "9p_txn_000042")
        XCTAssertEqual(r.created_at, "2026-07-18T04:07:11.000Z")
        XCTAssertEqual(r.updated_at, "2026-07-18T04:07:41.000Z")
    }

    func test_decode_pending() throws {
        let r = try decode("""
        {"intent_id":"zp_1","status":"pending","amount_usd_cents":14000,"corridor":"vn_vietqr"}
        """)
        XCTAssertEqual(r.receiptStatus, .pending)
        XCTAssertFalse(r.receiptStatus!.isTerminal)
        XCTAssertNil(r.merchant)
        XCTAssertNil(r.local_amount_minor_units)
    }

    func test_decode_failed() throws {
        let r = try decode("""
        {"intent_id":"zp_1","status":"failed","amount_usd_cents":14000}
        """)
        XCTAssertEqual(r.receiptStatus, .failed)
        XCTAssertTrue(r.receiptStatus!.isTerminal)
    }

    func test_decode_refunded() throws {
        let r = try decode("""
        {"intent_id":"zp_1","status":"refunded","amount_usd_cents":14000,
         "merchant":{"name":"Cà Phê Sài Gòn","account_no":"•••• 0000","bank_no":"970436","country":"VN"},
         "local_amount_minor_units":350000000,"local_currency":"704","transaction_ref":"9p_txn_9"}
        """)
        XCTAssertEqual(r.receiptStatus, .refunded)
        XCTAssertTrue(r.receiptStatus!.isTerminal)
        XCTAssertEqual(r.transaction_ref, "9p_txn_9")
    }

    func test_decode_unknownStatus_yieldsNilReceiptStatus() throws {
        let r = try decode("""
        {"intent_id":"zp_1","status":"authorized","amount_usd_cents":1}
        """)
        XCTAssertNil(r.receiptStatus)
    }

    /// Wire drift resilience: an alpha currency + string exchange_rate + missing
    /// amount must not fail the whole decode (soft fields tolerate it).
    func test_decode_toleratesAlphaCurrency_andStringRate_andMissingAmount() throws {
        let r = try decode("""
        {"intent_id":"zp_1","status":"captured","local_currency":"VND","exchange_rate":"25000.5"}
        """)
        XCTAssertEqual(r.local_currency, "VND")
        XCTAssertEqual(r.exchange_rate, 25000.5)
        XCTAssertEqual(r.amount_usd_cents, 0)
    }

    func test_decode_toleratesNonNumericRate() throws {
        let r = try decode("""
        {"intent_id":"zp_1","status":"captured","amount_usd_cents":10,"exchange_rate":"n/a"}
        """)
        XCTAssertNil(r.exchange_rate)
    }
}

// MARK: - Terminal-vs-pending routing

final class ReceiptStatusRoutingTests: XCTestCase {

    func test_terminalStatuses() {
        XCTAssertTrue(ReceiptStatus.captured.isTerminal)
        XCTAssertTrue(ReceiptStatus.failed.isTerminal)
        XCTAssertTrue(ReceiptStatus.refunded.isTerminal)
        XCTAssertFalse(ReceiptStatus.pending.isTerminal)
    }

    func test_currencyNumericNormalization() {
        XCTAssertEqual(CurrencyDisplay.numericCode(from: "VND"), "704")
        XCTAssertEqual(CurrencyDisplay.numericCode(from: "704"), "704")
        XCTAssertEqual(CurrencyDisplay.numericCode(from: "thb"), "764")
        XCTAssertEqual(CurrencyDisplay.numericCode(from: "USD"), "840")
        XCTAssertEqual(CurrencyDisplay.numericCode(from: "999"), "999")
        XCTAssertNil(CurrencyDisplay.numericCode(from: nil))
        XCTAssertNil(CurrencyDisplay.numericCode(from: ""))
    }
}

// MARK: - Receipt token light validation

final class ReceiptTokenValidationTests: XCTestCase {

    func test_emptyToken_throwsInvalidJWT() {
        XCTAssertThrowsError(try JWTClaims.lightDecodeReceiptToken("   ")) {
            XCTAssertEqual($0 as? ZennopayError, .invalidJWT)
        }
    }

    func test_wrongSegmentCount_throwsMalformed() {
        XCTAssertThrowsError(try JWTClaims.lightDecodeReceiptToken("a.b")) {
            XCTAssertEqual($0 as? ZennopayError, .malformedToken)
        }
    }

    func test_nonBase64Payload_throwsMalformed() {
        XCTAssertThrowsError(try JWTClaims.lightDecodeReceiptToken("h.!!!.s")) {
            XCTAssertEqual($0 as? ZennopayError, .malformedToken)
        }
    }

    func test_validReceiptToken_decodesSubAudExp() throws {
        let exp = Int(Date().addingTimeInterval(600).timeIntervalSince1970)
        let jwt = makeJWT(claims: [
            "sub": "demo_user_6",
            "aud": "zennopay-receipt",
            "iss": "https://demo.partner.test/issuer",
            "exp": exp,
        ])
        let claims = try JWTClaims.lightDecodeReceiptToken(jwt)
        XCTAssertEqual(claims.subject, "demo_user_6")
        XCTAssertEqual(claims.audience, "zennopay-receipt")
        XCTAssertEqual(claims.expiresAt?.timeIntervalSince1970, Double(exp))
    }

    /// A receipt token is NOT intent-bound and MUST decode even without the
    /// `zennopay:intent_id` claim that the checkout `validate` requires — and
    /// even when already expired (the backend re-mints on 401).
    func test_receiptToken_needsNoIntentClaim_andToleratesExpiry() throws {
        let jwt = makeJWT(claims: [
            "sub": "demo_user_6",
            "aud": "zennopay-receipt",
            "exp": Int(Date().addingTimeInterval(-3600).timeIntervalSince1970),
        ])
        XCTAssertNoThrow(try JWTClaims.lightDecodeReceiptToken(jwt))
    }
}

// MARK: - REST client receipt fetch + poll (stub transport)

final class ReceiptRESTClientTests: XCTestCase {

    private let config = ZennopayConfig(apiBaseURL: URL(string: "https://api.test.zennopay.com")!)

    static func receiptJSON(status: String) -> Data {
        """
        {"intent_id":"zp_1","status":"\(status)","amount_usd_cents":14000,
         "merchant":{"name":"Cà Phê Sài Gòn","account_no":"•••• 0000","bank_no":"970436","country":"VN"},
         "local_amount_minor_units":350000000,"local_currency":"704",
         "exchange_rate":25000.0,"fees":{"margin_usd_cents":210},
         "corridor":"vn_vietqr","transaction_ref":"9p_txn_42"}
        """.data(using: .utf8)!
    }
    static func errorJSON(_ code: String) -> Data {
        "{\"error\":{\"code\":\"\(code)\",\"message\":\"x\",\"request_id\":\"r\"}}".data(using: .utf8)!
    }

    func test_fetchReceipt_hitsReceiptPath_andDecodes() async throws {
        let stub = StubTransport { request in
            XCTAssertEqual(request.url?.path, "/v1/payment_intents/zp_1/receipt")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rcpt-1")
            return (Self.receiptJSON(status: "captured"), 200)
        }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "rcpt-1",
                                refreshSession: nil, transport: stub)
        let r = try await client.fetchReceipt()
        XCTAssertEqual(r.receiptStatus, .captured)
        XCTAssertEqual(r.merchant?.name, "Cà Phê Sài Gòn")
        XCTAssertEqual(r.amount_usd_cents, 14000)
    }

    func test_fetchReceipt_401_refreshesReceiptToken_thenRetries() async throws {
        let calls = Locked(0)
        let stub = StubTransport { request in
            let n = calls.mutate { $0 += 1; return $0 }
            if n == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stale")
                return (Self.errorJSON("authentication_failed"), 401)
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
            return (Self.receiptJSON(status: "captured"), 200)
        }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "stale",
                                refreshSession: { _ in "fresh" }, transport: stub)
        let r = try await client.fetchReceipt()
        XCTAssertEqual(r.receiptStatus, .captured)
        XCTAssertEqual(calls.value, 2)
    }

    func test_fetchReceipt_401_noRefresh_surfacesSessionExpired() async {
        let stub = StubTransport { _ in (Self.errorJSON("authentication_failed"), 401) }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "stale",
                                refreshSession: nil, transport: stub)
        do {
            _ = try await client.fetchReceipt()
            XCTFail("expected throw")
        } catch let e as ZennopayError {
            XCTAssertEqual(e, .sessionExpired)
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_fetchReceipt_404_mapsToServerError_noExistenceLeak() async {
        let stub = StubTransport { _ in (Self.errorJSON("not_found"), 404) }
        let client = RESTClient(config: config, intentID: "zp_unknown", sessionJWT: "rcpt",
                                refreshSession: nil, transport: stub)
        do {
            _ = try await client.fetchReceipt()
            XCTFail("expected throw")
        } catch let e as ZennopayError {
            XCTAssertEqual(e, .serverError(status: 404, code: "not_found"))
        } catch { XCTFail("wrong error: \(error)") }
    }

    func test_pollReceiptUntilTerminal_stopsWhenTerminal() async throws {
        let calls = Locked(0)
        let stub = StubTransport { _ in
            let n = calls.mutate { $0 += 1; return $0 }
            return (Self.receiptJSON(status: n < 3 ? "pending" : "captured"), 200)
        }
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "rcpt",
                                refreshSession: nil, transport: stub)
        let r = try await client.pollReceiptUntilTerminal(sleep: { _ in })
        XCTAssertEqual(r.receiptStatus, .captured)
        XCTAssertGreaterThanOrEqual(calls.value, 3)
    }

    func test_pollReceiptUntilTerminal_timesOut_whenStuckPending() async {
        let cfg = ZennopayConfig(apiBaseURL: config.apiBaseURL, statusPollTimeout: 0, maxPollInterval: 1)
        let stub = StubTransport { _ in (Self.receiptJSON(status: "pending"), 200) }
        let client = RESTClient(config: cfg, intentID: "zp_1", sessionJWT: "rcpt",
                                refreshSession: nil, transport: stub)
        do {
            _ = try await client.pollReceiptUntilTerminal(sleep: { _ in })
            XCTFail("expected timeout")
        } catch let e as ZennopayError {
            XCTAssertEqual(e, .timedOut)
        } catch { XCTFail("wrong error: \(error)") }
    }
}

// MARK: - Receipt flow routing (view model, terminal vs pending)

#if canImport(SwiftUI)
@available(iOS 14.0, macOS 13.0, *)
@MainActor
final class ReceiptFlowViewModelTests: XCTestCase {

    private let config = ZennopayConfig(apiBaseURL: URL(string: "https://api.test.zennopay.com")!)

    private func makeVM(transport: HTTPTransport, refresh: (@Sendable (String) async -> String?)? = nil,
                        onResult: @escaping (PaymentResult) -> Void = { _ in }) -> CheckoutViewModel {
        let client = RESTClient(config: config, intentID: "zp_1", sessionJWT: "rcpt",
                                refreshSession: refresh, transport: transport)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zp-rcpt-\(UUID().uuidString)")
        return CheckoutViewModel(intentID: "zp_1", config: config, client: client,
                                 store: IdempotencyStore(directory: dir), onResult: onResult)
    }

    func test_capturedReceipt_routesToCompletedReceipt() async {
        let stub = StubTransport { _ in (ReceiptRESTClientTests.receiptJSON(status: "captured"), 200) }
        let vm = makeVM(transport: stub)
        await vm.runReceiptFlow()
        XCTAssertEqual(vm.state, .finished(.completed(intentID: "zp_1")))
        XCTAssertEqual(vm.receiptDisplayStatus, .captured)
        // Fields mapped onto the display receipt.
        XCTAssertEqual(vm.receipt?.usdCents, 14000)
        XCTAssertEqual(vm.receipt?.localMinorUnits, 350000000)
        XCTAssertEqual(vm.receipt?.localCurrency, "704")
        XCTAssertEqual(vm.receipt?.transactionID, "9p_txn_42")
        XCTAssertEqual(vm.receipt?.accountMasked, "•••• 0000")
        XCTAssertEqual(vm.displayMerchantName, "Cà Phê Sài Gòn")
    }

    func test_refundedReceipt_routesToCompleted_withRefundStatus() async {
        let stub = StubTransport { _ in (ReceiptRESTClientTests.receiptJSON(status: "refunded"), 200) }
        let vm = makeVM(transport: stub)
        await vm.runReceiptFlow()
        XCTAssertEqual(vm.state, .finished(.completed(intentID: "zp_1")))
        XCTAssertEqual(vm.receiptDisplayStatus, .refunded)
    }

    func test_failedReceipt_routesToFailure() async {
        let stub = StubTransport { _ in (ReceiptRESTClientTests.receiptJSON(status: "failed"), 200) }
        let vm = makeVM(transport: stub)
        await vm.runReceiptFlow()
        guard case .finished(.failed) = vm.state else {
            return XCTFail("expected finished failed, got \(vm.state)")
        }
        XCTAssertEqual(vm.receiptDisplayStatus, .failed)
    }

    func test_pendingReceipt_showsPending_thenPollsToCaptured() async {
        let calls = Locked(0)
        let stub = StubTransport { _ in
            let n = calls.mutate { $0 += 1; return $0 }
            return (ReceiptRESTClientTests.receiptJSON(status: n < 2 ? "pending" : "captured"), 200)
        }
        let vm = makeVM(transport: stub)
        await vm.runReceiptFlow()
        XCTAssertEqual(vm.state, .finished(.completed(intentID: "zp_1")))
        XCTAssertEqual(vm.receiptDisplayStatus, .captured)
    }

    func test_preflightError_landsOnFailure_withoutNetwork() async {
        let stub = StubTransport { _ in XCTFail("must not hit network"); return (Data(), 200) }
        let vm = makeVM(transport: stub)
        await vm.runReceiptFlow(preflightError: .malformedToken)
        guard case .finished(.failed(_, let err)) = vm.state else {
            return XCTFail("expected finished failed, got \(vm.state)")
        }
        XCTAssertEqual(err, .malformedToken)
    }

    func test_401_noRefresh_landsOnFailure() async {
        let stub = StubTransport { _ in (ReceiptRESTClientTests.errorJSON("authentication_failed"), 401) }
        let vm = makeVM(transport: stub)
        await vm.runReceiptFlow()
        guard case .finished(.failed(_, let err)) = vm.state else {
            return XCTFail("expected finished failed, got \(vm.state)")
        }
        XCTAssertEqual(err, .sessionExpired)
    }
}
#endif
