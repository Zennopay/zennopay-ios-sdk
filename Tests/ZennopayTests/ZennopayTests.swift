import XCTest
@testable import Zennopay

final class ZennopayTests: XCTestCase {

    // MARK: - parseReturnURL: happy path

    func test_parseReturnURL_extractsIntentIDAndStatus_fromValidURL() {
        let url = URL(string: "wizz://payment-result?intent_id=zp_abc&status=success")!

        let result = Zennopay.parseReturnURL(url)

        switch result {
        case .success(let payment):
            XCTAssertEqual(payment.intentID, "zp_abc")
            XCTAssertEqual(payment.status, .success)
        case .failure(let err):
            XCTFail("Expected .success, got .failure(\(err))")
        }
    }

    // MARK: - parseReturnURL: missing params

    func test_parseReturnURL_returnsMalformed_whenIntentIDMissing() {
        let url = URL(string: "wizz://payment-result?status=success")!

        let result = Zennopay.parseReturnURL(url)

        XCTAssertEqual(result.failureValue, .returnURLMalformed)
    }

    func test_parseReturnURL_returnsMalformed_whenStatusMissing() {
        let url = URL(string: "wizz://payment-result?intent_id=zp_abc")!

        let result = Zennopay.parseReturnURL(url)

        XCTAssertEqual(result.failureValue, .returnURLMalformed)
    }

    func test_parseReturnURL_returnsMalformed_whenStatusIsUnknownValue() {
        let url = URL(string: "wizz://payment-result?intent_id=zp_abc&status=garbage")!

        let result = Zennopay.parseReturnURL(url)

        XCTAssertEqual(result.failureValue, .returnURLMalformed)
    }

    func test_parseReturnURL_returnsMalformed_whenIntentIDIsEmpty() {
        let url = URL(string: "wizz://payment-result?intent_id=&status=success")!

        let result = Zennopay.parseReturnURL(url)

        XCTAssertEqual(result.failureValue, .returnURLMalformed)
    }

    // MARK: - parseReturnURL: all status values

    func test_parseReturnURL_handlesAllStatusValues() {
        let cases: [(String, PaymentStatus)] = [
            ("success", .success),
            ("failed", .failed),
            ("canceled", .canceled),
            ("pending", .pending)
        ]

        for (raw, expected) in cases {
            let url = URL(string: "wizz://payment-result?intent_id=zp_xyz&status=\(raw)")!
            let result = Zennopay.parseReturnURL(url)
            switch result {
            case .success(let payment):
                XCTAssertEqual(payment.intentID, "zp_xyz", "intentID mismatch for status=\(raw)")
                XCTAssertEqual(payment.status, expected, "status mismatch for raw=\(raw)")
            case .failure(let err):
                XCTFail("Expected .success for status=\(raw), got .failure(\(err))")
            }
        }
    }

    // MARK: - buildCheckoutURL

    func test_buildCheckoutURL_putsJWTInFragmentNotQuery() {
        let url = Zennopay.buildCheckoutURL(intentID: "zp_abc123", jwt: "eyJhbGciOiJIUzI1NiJ9.payload.sig")
        let urlString = url.absoluteString

        // Token must live in the fragment.
        XCTAssertTrue(
            urlString.contains("#token=eyJhbGciOiJIUzI1NiJ9.payload.sig"),
            "Expected token in fragment, got: \(urlString)"
        )

        // Token must NOT appear as a query parameter.
        XCTAssertFalse(
            urlString.contains("?token="),
            "Token leaked into query string: \(urlString)"
        )
        XCTAssertFalse(
            urlString.contains("&token="),
            "Token leaked into query string: \(urlString)"
        )

        // Host + path shape sanity.
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "checkout.zennopay.com")
        XCTAssertEqual(url.path, "/flow/zp_abc123/scan")
        XCTAssertEqual(url.fragment, "token=eyJhbGciOiJIUzI1NiJ9.payload.sig")

        // URL must have no query items at all — JWT in query would be a leak.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        XCTAssertNil(components?.queryItems, "URL should have no query items; JWT belongs in fragment")
    }

    // MARK: - JWTClaims.validate: happy path

    func test_jwtValidate_succeeds_whenIntentIDMatchesAndNotExpired() throws {
        let exp = Date().addingTimeInterval(300) // 5 minutes in the future
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_abc123",
            "exp": Int(exp.timeIntervalSince1970),
            "iss": "wizz.app"
        ])

        let decoded = try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        XCTAssertEqual(decoded.intentID, "zp_abc123")
        XCTAssertEqual(decoded.issuer, "wizz.app")
    }

    // MARK: - JWTClaims.validate: intent mismatch

    func test_jwtValidate_throwsIntentMismatch_whenClaimIntentDiffersFromArgument() {
        let exp = Date().addingTimeInterval(300)
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_OTHER",
            "exp": Int(exp.timeIntervalSince1970),
            "iss": "wizz.app"
        ])

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .intentMismatch)
        }
    }

    // MARK: - JWTClaims.validate: expired

    func test_jwtValidate_throwsExpired_whenExpInThePastBeyondSkewTolerance() {
        // 5 minutes in the past — well beyond the 30s skew window.
        let exp = Date().addingTimeInterval(-300)
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_abc123",
            "exp": Int(exp.timeIntervalSince1970),
            "iss": "wizz.app"
        ])

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .jwtExpired)
        }
    }

    func test_jwtValidate_acceptsToken_withinClockSkewTolerance() throws {
        // Expired 10 seconds ago — inside the default 30s skew tolerance.
        let exp = Date().addingTimeInterval(-10)
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_abc123",
            "exp": Int(exp.timeIntervalSince1970),
            "iss": "wizz.app"
        ])

        XCTAssertNoThrow(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        )
    }

    // MARK: - JWTClaims.validate: malformed

    func test_jwtValidate_throwsMalformed_whenTokenHasOnlyTwoSegments() {
        let jwt = "header.payload" // missing signature segment

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .malformedToken)
        }
    }

    func test_jwtValidate_throwsMalformed_whenPayloadIsNotBase64() {
        let jwt = "header.!!!not-base64!!!.sig"

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .malformedToken)
        }
    }

    func test_jwtValidate_throwsMalformed_whenPayloadIsNotJSONObject() {
        // A base64url-encoded JSON *array*, not an object.
        let payloadJSON = "[1,2,3]".data(using: .utf8)!
        let payloadB64 = base64URLEncode(payloadJSON)
        let jwt = "header.\(payloadB64).sig"

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .malformedToken)
        }
    }

    // MARK: - JWTClaims.validate: missing claims

    func test_jwtValidate_throwsMissingClaim_whenIntentIDClaimAbsent() {
        let exp = Date().addingTimeInterval(300)
        let jwt = makeJWT(claims: [
            "exp": Int(exp.timeIntervalSince1970),
            "iss": "wizz.app"
        ])

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .jwtMissingClaim)
        }
    }

    func test_jwtValidate_throwsMissingClaim_whenIssuerEmpty() {
        let exp = Date().addingTimeInterval(300)
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_abc123",
            "exp": Int(exp.timeIntervalSince1970),
            "iss": ""
        ])

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .jwtMissingClaim)
        }
    }

    func test_jwtValidate_throwsMissingClaim_whenExpAbsent() {
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_abc123",
            "iss": "wizz.app"
        ])

        XCTAssertThrowsError(
            try JWTClaims.validate(jwt: jwt, expectedIntentID: "zp_abc123")
        ) { error in
            XCTAssertEqual(error as? ZennopayError, .jwtMissingClaim)
        }
    }

    // MARK: - openCheckout: surfaces JWT errors synchronously, before opening browser

    func test_openCheckout_failsWithIntentMismatch_andDoesNotInvokeBrowser() {
        let exp = Date().addingTimeInterval(300)
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_DIFFERENT",
            "exp": Int(exp.timeIntervalSince1970),
            "iss": "wizz.app"
        ])

        let expectation = XCTestExpectation(description: "completion fires with .intentMismatch")
        Zennopay.openCheckout(
            intentID: "zp_abc123",
            jwt: jwt,
            returnScheme: "wizz"
        ) { result in
            if case .failure(let err) = result, err == .intentMismatch {
                expectation.fulfill()
            } else {
                XCTFail("expected .failure(.intentMismatch), got \(result)")
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func test_openCheckout_failsWithExpired_forStaleToken() {
        let exp = Date().addingTimeInterval(-600)
        let jwt = makeJWT(claims: [
            "zennopay:intent_id": "zp_abc123",
            "exp": Int(exp.timeIntervalSince1970),
            "iss": "wizz.app"
        ])

        let expectation = XCTestExpectation(description: "completion fires with .jwtExpired")
        Zennopay.openCheckout(
            intentID: "zp_abc123",
            jwt: jwt,
            returnScheme: "wizz"
        ) { result in
            if case .failure(let err) = result, err == .jwtExpired {
                expectation.fulfill()
            } else {
                XCTFail("expected .failure(.jwtExpired), got \(result)")
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func test_openCheckout_failsWithMalformed_forGarbageToken() {
        let expectation = XCTestExpectation(description: "completion fires with .malformedToken")
        Zennopay.openCheckout(
            intentID: "zp_abc123",
            jwt: "not.a.valid.jwt.with.too.many.segments",
            returnScheme: "wizz"
        ) { result in
            if case .failure(let err) = result, err == .malformedToken {
                expectation.fulfill()
            } else {
                XCTFail("expected .failure(.malformedToken), got \(result)")
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }
}

// MARK: - JWT test helpers

private extension ZennopayTests {
    /// Build a fake unsigned JWT for testing — header and signature are
    /// placeholders since the SDK only inspects the payload segment.
    func makeJWT(claims: [String: Any]) -> String {
        let header = ["alg": "RS256", "typ": "JWT"]
        let headerData = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try! JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return "\(base64URLEncode(headerData)).\(base64URLEncode(payloadData)).sig"
    }

    func base64URLEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Test helpers

private extension Result {
    var failureValue: Failure? {
        if case .failure(let e) = self { return e }
        return nil
    }
}
