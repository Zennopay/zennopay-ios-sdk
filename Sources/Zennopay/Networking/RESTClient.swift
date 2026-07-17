import Foundation

/// Abstraction over the network transport so tests can inject a stub without a
/// live server. Mirrors the one method of `URLSession` the client uses.
protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

/// The SDK's REST client for the three SDK-facing endpoints.
///
/// Responsibilities (design doc: "REST client" native SDK task):
///  - Holds the session JWT in memory; sends it as `Authorization: Bearer`.
///  - On 401 (session expired) calls the host `refreshSession` hook once and
///    retries the request with the fresh token (D3=A). `/scan` and `GET` may
///    be replayed freely (D2=B); `/confirm` burns its jti, so a refreshed
///    token is required to retry it.
///  - Bounded status polling with capped exponential backoff.
///
/// The client is an `actor` so the in-memory JWT and the "refresh in flight"
/// state are mutated safely under concurrency.
actor RESTClient {

    private let config: ZennopayConfig
    private let transport: HTTPTransport
    private let intentID: String

    /// The current session JWT. Swapped in place on refresh.
    private var sessionJWT: String

    /// Host-provided refresh hook. Given the intent ID, returns a fresh session
    /// JWT (or nil if it can't mint one). Optional — when nil, a 401 is fatal.
    private let refreshSession: (@Sendable (String) async -> String?)?

    /// Guards against stampeding refreshes when several calls 401 at once.
    private var refreshTask: Task<String?, Never>?

    init(
        config: ZennopayConfig,
        intentID: String,
        sessionJWT: String,
        refreshSession: (@Sendable (String) async -> String?)?,
        transport: HTTPTransport
    ) {
        self.config = config
        self.intentID = intentID
        self.sessionJWT = sessionJWT
        self.refreshSession = refreshSession
        self.transport = transport
    }

    // MARK: - Endpoints

    /// `POST /v1/payment_intents/:id/scan`. Submits the raw QR payload; returns
    /// the validated merchant + FX quote. Replayable, so a 401 → refresh → retry
    /// is always safe here.
    ///
    /// The corridor is NOT sent — the backend takes it from the session JWT's
    /// `zennopay:corridor` claim. `localAmountMinorUnits` is required for a
    /// STATIC QR (user-entered amount) and omitted for a dynamic QR.
    func scan(qrPayload: String, localAmountMinorUnits: Int? = nil) async throws -> ScanResponse {
        let body = try JSONEncoder().encode(
            ScanRequest(qr_payload: qrPayload, local_amount_minor_units: localAmountMinorUnits)
        )
        let request = makeRequest(path: "scan", method: "POST", body: body)
        return try await send(request, decode: ScanResponse.self, allowRefreshRetry: true)
    }

    /// `POST /v1/payment_intents/:id/confirm` with a stable idempotency key and
    /// the quote binding (`quote_id` + `quote_version`) from the scan quote.
    /// The jti is single-use, so on a 401 we refresh and retry ONCE with the
    /// same idempotency key (the backend dedupes the money movement).
    func confirm(quoteID: String, quoteVersion: Int, idempotencyKey: String) async throws -> ConfirmResponse {
        let confirmBody = try JSONEncoder().encode(
            ConfirmRequest(quote_id: quoteID, quote_version: quoteVersion)
        )
        func build() -> URLRequest {
            var r = makeRequest(path: "confirm", method: "POST", body: confirmBody)
            r.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
            return r
        }
        return try await send(
            build(),
            decode: ConfirmResponse.self,
            allowRefreshRetry: true,
            onConfirm: true,
            rebuildAfterRefresh: build
        )
    }

    /// `GET /v1/payment_intents/:id`. Single status read. Replayable.
    func fetchStatus() async throws -> IntentSnapshot {
        let request = makeRequest(path: nil, method: "GET", body: nil)
        return try await send(request, decode: IntentSnapshot.self, allowRefreshRetry: true)
    }

    /// `GET /v1/payment_intents/:id/receipt`. Reads the authoritative receipt
    /// for a past payment. Authenticated by the partner-minted RECEIPT token
    /// (`aud = zennopay-receipt`), carried as `Authorization: Bearer` like every
    /// other call. Replayable (the token is reusable for polling), so a 401 →
    /// `refreshSession` (the receipt-token re-mint hook) → retry is always safe.
    func fetchReceipt() async throws -> ReceiptDTO {
        let request = makeRequest(path: "receipt", method: "GET", body: nil)
        return try await send(request, decode: ReceiptDTO.self, allowRefreshRetry: true)
    }

    /// Poll `GET /:id/receipt` with capped exponential backoff until the receipt
    /// status is terminal (captured/failed/refunded) or the poll timeout.
    /// Returns the terminal receipt, or throws `.timedOut`.
    func pollReceiptUntilTerminal(
        sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> ReceiptDTO {
        let deadline = Date().addingTimeInterval(config.statusPollTimeout)
        var interval: TimeInterval = 0.5
        while true {
            let receipt = try await fetchReceipt()
            if let status = ReceiptStatus(rawValue: receipt.status), status.isTerminal {
                return receipt
            }
            if Date() >= deadline {
                throw ZennopayError.timedOut
            }
            try await sleep(UInt64(interval * 1_000_000_000))
            interval = min(interval * 2, config.maxPollInterval)
        }
    }

    /// Poll `GET /:id` with capped exponential backoff until a terminal status
    /// or the poll timeout. Returns the terminal snapshot, or throws
    /// `.timedOut`.
    func pollUntilTerminal(
        sleep: @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async throws -> IntentSnapshot {
        let deadline = Date().addingTimeInterval(config.statusPollTimeout)
        var interval: TimeInterval = 0.5
        while true {
            let snapshot = try await fetchStatus()
            if let status = IntentStatus(rawValue: snapshot.status), status.isTerminal {
                return snapshot
            }
            if Date() >= deadline {
                throw ZennopayError.timedOut
            }
            try await sleep(UInt64(interval * 1_000_000_000))
            interval = min(interval * 2, config.maxPollInterval)
        }
    }

    // MARK: - Request building

    private func makeRequest(path: String?, method: String, body: Data?) -> URLRequest {
        var url = config.apiBaseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("payment_intents")
            .appendingPathComponent(intentID)
        if let path {
            url = url.appendingPathComponent(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(sessionJWT)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - Send + 401 refresh

    private func send<T: Decodable>(
        _ request: URLRequest,
        decode type: T.Type,
        allowRefreshRetry: Bool,
        onConfirm: Bool = false,
        rebuildAfterRefresh: (() -> URLRequest)? = nil
    ) async throws -> T {
        let (data, response) = try await perform(request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if (200..<300).contains(status) {
            return try decodeBody(data, as: T.self)
        }

        // 401 → attempt one refresh + retry with the fresh token.
        if status == 401, allowRefreshRetry, let refreshed = await refreshOnce() {
            self.sessionJWT = refreshed
            // Rebuild so the Authorization header (and any per-request headers
            // like Idempotency-Key) are re-applied with the new token.
            let retried = rebuildAfterRefresh?() ?? makeRequestReplacingAuth(request)
            let (data2, response2) = try await perform(retried)
            let status2 = (response2 as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status2) {
                return try decodeBody(data2, as: T.self)
            }
            throw mapError(status: status2, data: data2, onConfirm: onConfirm)
        }

        throw mapError(status: status, data: data, onConfirm: onConfirm)
    }

    /// Re-stamp an existing request's Authorization header with the current
    /// (refreshed) JWT. Used for GET/scan where the body is already set.
    private func makeRequestReplacingAuth(_ original: URLRequest) -> URLRequest {
        var r = original
        r.setValue("Bearer \(sessionJWT)", forHTTPHeaderField: "Authorization")
        return r
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport.data(for: request)
        } catch {
            throw ZennopayError.networkError(underlying: String(describing: error))
        }
    }

    /// Single-flight refresh: concurrent 401s share one `refreshSession` call.
    private func refreshOnce() async -> String? {
        guard let refreshSession else { return nil }
        if let existing = refreshTask {
            return await existing.value
        }
        let intentID = self.intentID
        let task = Task<String?, Never> {
            await refreshSession(intentID)
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    // MARK: - Decoding + error mapping

    private func decodeBody<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ZennopayError.serverError(status: 200, code: "response_decode_failed")
        }
    }

    private func mapError(status: Int, data: Data, onConfirm: Bool) -> ZennopayError {
        let code = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code
        return ZennopayError.from(httpStatus: status, code: code, onConfirm: onConfirm)
    }
}
