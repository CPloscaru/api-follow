import Foundation
import Testing
@testable import APIFollow

@Suite("OpenRouterAdapter")
struct OpenRouterAdapterTests {
    @Test("parses a well-formed activity response, one record per model per day")
    func parsesWellFormedResponse() {
        let json = """
        {
          "data": [
            { "date": "2026-07-01", "model": "openai/gpt-4.1", "usage": 0.015, "provider_name": "OpenAI", "requests": 5 },
            { "date": "2026-07-01", "model": "anthropic/claude-opus-4.8", "usage": 1.20, "provider_name": "Anthropic", "requests": 2 }
          ]
        }
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.attributionID == "account" && $0.attributionKind == .workspace })
        #expect(records.contains { $0.model == "openai/gpt-4.1" && $0.amountUSD == Decimal(string: "0.015000") })
    }

    @Test("negative usage surfaces parseError, not a silently wrong amount")
    func negativeUsageIsParseError() {
        let json = """
        {"data": [{"date": "2026-07-01", "model": "x", "usage": -1.0, "provider_name": null}]}
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("malformed date surfaces parseError")
    func malformedDateIsParseError() {
        let json = """
        {"data": [{"date": "not-a-date", "model": "x", "usage": 1.0, "provider_name": null}]}
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("401 response classifies as authError")
    func unauthorizedClassifiesAsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let adapter = OpenRouterAdapter(httpClient: client)
        let result = await adapter.fetchSpend(adminKey: "bad-key", since: Date(), until: Date())
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }
}
