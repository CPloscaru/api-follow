import Foundation
import Testing
@testable import APIFollow

@Suite("FalAdapter")
struct FalAdapterTests {
    @Test("parses a well-formed usage response, one record per model per bucket")
    func parsesWellFormedResponse() {
        let json = """
        {
          "time_series": [
            {
              "bucket": "2026-07-01T00:00:00Z",
              "results": [
                { "endpoint_id": "fal-ai/flux/dev", "unit": "image", "quantity": 4, "unit_price": 0.1, "cost": 0.4, "currency": "USD", "auth_method": "Production Key" },
                { "endpoint_id": "fal-ai/kling-video", "unit": "second", "quantity": 10, "unit_price": 0.05, "cost": 0.5, "currency": "USD", "auth_method": "Production Key" }
              ]
            }
          ],
          "summary": [],
          "next_cursor": null,
          "has_more": false
        }
        """.data(using: .utf8)!

        let result = FalAdapter.parse(json)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.attributionID == "account" && $0.attributionKind == .workspace })
        #expect(records.contains { $0.model == "fal-ai/flux/dev" && $0.amountUSD == Decimal(string: "0.400000") })
        // quantity/unit deliberately NOT mapped into requests — see FalAdapter's doc comment.
        #expect(records.allSatisfy { $0.requests == nil })
    }

    @Test("unexpected currency surfaces parseError, not a silently wrong amount")
    func unexpectedCurrencyIsParseError() {
        let json = """
        {"time_series": [{"bucket": "2026-07-01T00:00:00Z", "results": [
          {"endpoint_id": "x", "unit": "image", "quantity": 1, "unit_price": 1.0, "cost": 1.0, "currency": "EUR", "auth_method": "k"}
        ]}]}
        """.data(using: .utf8)!

        let result = FalAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("negative cost surfaces parseError")
    func negativeCostIsParseError() {
        let json = """
        {"time_series": [{"bucket": "2026-07-01T00:00:00Z", "results": [
          {"endpoint_id": "x", "unit": "image", "quantity": 1, "unit_price": 1.0, "cost": -1.0, "currency": "USD", "auth_method": "k"}
        ]}]}
        """.data(using: .utf8)!

        let result = FalAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("malformed bucket timestamp surfaces parseError")
    func malformedBucketIsParseError() {
        let json = """
        {"time_series": [{"bucket": "not-a-date", "results": []}]}
        """.data(using: .utf8)!

        let result = FalAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("missing required field (time_series) surfaces parseError, not a crash")
    func missingRequiredFieldIsParseError() {
        let json = "{}".data(using: .utf8)!
        let result = FalAdapter.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("401 response classifies as authError")
    func unauthorizedClassifiesAsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let adapter = FalAdapter(httpClient: client)
        let result = await adapter.fetchSpend(adminKey: "bad-key", since: Date(), until: Date())
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }
}
