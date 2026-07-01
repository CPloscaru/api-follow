import Foundation
import Testing
@testable import APIFollow

struct MockHTTPClient: HTTPClient {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (body, response)
    }
}

struct ThrowingHTTPClient: HTTPClient {
    struct SomeNetworkError: Error {}
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw SomeNetworkError()
    }
}

@Suite("AnthropicAdapter")
struct AnthropicAdapterTests {
    @Test("parses a well-formed cost report response")
    func parsesWellFormedResponse() {
        let json = """
        {
          "data": [
            {
              "starting_at": "2026-07-01T00:00:00Z",
              "ending_at": "2026-07-02T00:00:00Z",
              "results": [
                { "amount": "12.34", "currency": "USD", "workspace_id": "wrkspc_abc", "description": null }
              ]
            }
          ],
          "has_more": false
        }
        """.data(using: .utf8)!

        let result = AnthropicAdapter.parse(json)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.count == 1)
        #expect(records.first?.amountUSD == Decimal(string: "12.34"))
        #expect(records.first?.attributionID == "wrkspc_abc")
        #expect(records.first?.attributionKind == .workspace)
    }

    @Test("default workspace (null workspace_id) maps to 'default', not dropped")
    func defaultWorkspaceIsHandled() {
        let json = """
        {"data": [{"starting_at": "2026-07-01T00:00:00Z", "ending_at": "2026-07-02T00:00:00Z",
          "results": [{"amount": "1.00", "currency": "USD", "workspace_id": null, "description": null}]}], "has_more": false}
        """.data(using: .utf8)!

        let result = AnthropicAdapter.parse(json)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.first?.attributionID == "default")
    }

    @Test("unexpected currency surfaces parseError, not a silently wrong amount")
    func unexpectedCurrencyIsParseError() {
        let json = """
        {"data": [{"starting_at": "2026-07-01T00:00:00Z", "ending_at": "2026-07-02T00:00:00Z",
          "results": [{"amount": "1.00", "currency": "EUR", "workspace_id": null, "description": null}]}], "has_more": false}
        """.data(using: .utf8)!

        let result = AnthropicAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("malformed amount string surfaces parseError")
    func malformedAmountIsParseError() {
        let json = """
        {"data": [{"starting_at": "2026-07-01T00:00:00Z", "ending_at": "2026-07-02T00:00:00Z",
          "results": [{"amount": "not-a-number", "currency": "USD", "workspace_id": null, "description": null}]}], "has_more": false}
        """.data(using: .utf8)!

        let result = AnthropicAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("missing required field (data) surfaces parseError, not a crash")
    func missingRequiredFieldIsParseError() {
        let json = "{}".data(using: .utf8)!
        let result = AnthropicAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("401 response classifies as authError")
    func unauthorizedClassifiesAsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let adapter = AnthropicAdapter(httpClient: client)
        let result = await adapter.fetchSpend(adminKey: "bad-key", since: Date(), until: Date())
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }

    @Test("429 response classifies as rateLimited")
    func rateLimitClassifiesAsRateLimited() async {
        let client = MockHTTPClient(statusCode: 429, body: Data(), headers: ["Retry-After": "30"])
        let adapter = AnthropicAdapter(httpClient: client)
        let result = await adapter.fetchSpend(adminKey: "key", since: Date(), until: Date())
        guard case .rateLimited(let retryAfter) = result else {
            Issue.record("expected .rateLimited, got \(result)")
            return
        }
        #expect(retryAfter != nil)
    }

    @Test("500 response classifies as transientFailure")
    func serverErrorClassifiesAsTransient() async {
        let client = MockHTTPClient(statusCode: 500, body: Data())
        let adapter = AnthropicAdapter(httpClient: client)
        let result = await adapter.fetchSpend(adminKey: "key", since: Date(), until: Date())
        guard case .transientFailure = result else {
            Issue.record("expected .transientFailure, got \(result)")
            return
        }
    }

    @Test("network error (e.g. no connection) classifies as transientFailure")
    func networkErrorClassifiesAsTransient() async {
        let adapter = AnthropicAdapter(httpClient: ThrowingHTTPClient())
        let result = await adapter.fetchSpend(adminKey: "key", since: Date(), until: Date())
        guard case .transientFailure = result else {
            Issue.record("expected .transientFailure, got \(result)")
            return
        }
    }
}

@Suite("OpenAIAdapter")
struct OpenAIAdapterTests {
    @Test("parses a well-formed costs response with real per-key attribution")
    func parsesWellFormedResponseWithApiKeyId() {
        let json = """
        {
          "data": [
            {
              "start_time": 1751328000,
              "end_time": 1751414400,
              "results": [
                { "amount": { "value": 3.5, "currency": "usd" }, "api_key_id": "key_abc123", "project_id": "proj_1", "line_item": null, "quantity": null }
              ]
            }
          ],
          "has_more": false
        }
        """.data(using: .utf8)!

        let result = OpenAIAdapter.parse(json)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.count == 1)
        #expect(records.first?.attributionID == "key_abc123")
        #expect(records.first?.attributionKind == .apiKey)
    }

    @Test("missing api_key_id (e.g. Workbench usage) does not crash, uses fallback id")
    func missingApiKeyIdUsesFallback() {
        let json = """
        {"data": [{"start_time": 1751328000, "end_time": 1751414400,
          "results": [{"amount": {"value": 1.0, "currency": "usd"}, "api_key_id": null, "project_id": null, "line_item": null, "quantity": null}]}], "has_more": false}
        """.data(using: .utf8)!

        let result = OpenAIAdapter.parse(json)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.first?.attributionID == "no-api-key-id")
    }

    @Test("401 response classifies as authError")
    func unauthorizedClassifiesAsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let adapter = OpenAIAdapter(httpClient: client)
        let result = await adapter.fetchSpend(adminKey: "bad-key", since: Date(), until: Date())
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }
}
