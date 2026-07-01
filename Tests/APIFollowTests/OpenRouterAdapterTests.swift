import Foundation
import Testing
@testable import APIFollow

@Suite("OpenRouterAdapter")
struct OpenRouterAdapterTests {
    @Test("parses a well-formed activity response, one record per model per day, with token detail")
    func parsesWellFormedResponse() {
        let json = """
        {
          "data": [
            { "date": "2026-07-01", "model": "openai/gpt-4.1", "usage": 0.015, "provider_name": "OpenAI",
              "requests": 5, "prompt_tokens": 1200, "completion_tokens": 300, "reasoning_tokens": 0 },
            { "date": "2026-07-01", "model": "anthropic/claude-opus-4.8", "usage": 1.20, "provider_name": "Anthropic",
              "requests": 2, "prompt_tokens": 4000, "completion_tokens": 800, "reasoning_tokens": 150 }
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

        let gpt = records.first { $0.model == "openai/gpt-4.1" }
        #expect(gpt?.amountUSD == Decimal(string: "0.015000"))
        #expect(gpt?.requests == 5)
        #expect(gpt?.promptTokens == 1200)
        #expect(gpt?.completionTokens == 300)
        #expect(gpt?.reasoningTokens == 0)

        let claude = records.first { $0.model == "anthropic/claude-opus-4.8" }
        #expect(claude?.reasoningTokens == 150)
    }

    @Test("missing token/request fields default to nil, not a crash")
    func missingTokenFieldsDefaultToNil() {
        let json = """
        {"data": [{"date": "2026-07-01", "model": "x", "usage": 1.0, "provider_name": null}]}
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.first?.requests == nil)
        #expect(records.first?.promptTokens == nil)
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

    @Test("missing required field (data) surfaces parseError, not a crash")
    func missingRequiredFieldIsParseError() {
        let json = "{}".data(using: .utf8)!
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

    @Test("modelBreakdown aggregates requests and tokens per model across days")
    func modelBreakdownAggregatesAcrossDays() throws {
        let store = try SpendStore(inMemory: ())
        let day1 = """
        {"data": [{"date": "2026-07-01", "model": "openai/gpt-4.1", "usage": 1.0, "requests": 3, "prompt_tokens": 100, "completion_tokens": 50, "reasoning_tokens": 0}]}
        """.data(using: .utf8)!
        let day2 = """
        {"data": [{"date": "2026-07-02", "model": "openai/gpt-4.1", "usage": 2.0, "requests": 4, "prompt_tokens": 150, "completion_tokens": 75, "reasoning_tokens": 0}]}
        """.data(using: .utf8)!

        guard case .success(let r1) = OpenRouterAdapter.parse(day1) else { Issue.record("parse failed"); return }
        guard case .success(let r2) = OpenRouterAdapter.parse(day2) else { Issue.record("parse failed"); return }
        try store.write(r1)
        try store.write(r2)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let from = calendar.date(from: DateComponents(year: 2026, month: 7, day: 1))!
        let to = calendar.date(from: DateComponents(year: 2026, month: 7, day: 3))!

        let breakdown = try store.modelBreakdown(for: .openrouter, from: from, to: to)
        #expect(breakdown.count == 1)
        #expect(breakdown.first?.amountUSD == 3.0)
        #expect(breakdown.first?.requests == 7)
        #expect(breakdown.first?.promptTokens == 250)
    }
}
