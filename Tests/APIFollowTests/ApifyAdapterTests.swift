import Foundation
import Testing
@testable import APIFollow

@Suite("ApifyAdapter")
struct ApifyAdapterTests {
    private let since = Date(timeIntervalSince1970: 0)
    private let until = Date(timeIntervalSince1970: 4_000_000_000)

    @Test("parses a well-formed monthly usage response, one record per day")
    func parsesWellFormedResponse() {
        let json = """
        {
          "data": {
            "usageCycle": {"startAt": "2026-07-01T00:00:00.000Z", "endAt": "2026-07-31T23:59:59.999Z"},
            "dailyServiceUsages": [
              {"date": "2026-07-01T00:00:00.000Z", "serviceUsage": {}, "totalUsageCreditsUsd": 1.5},
              {"date": "2026-07-02T00:00:00.000Z", "serviceUsage": {}, "totalUsageCreditsUsd": 2.25}
            ],
            "totalUsageCreditsUsdBeforeVolumeDiscount": 3.75,
            "totalUsageCreditsUsdAfterVolumeDiscount": 3.75
          }
        }
        """.data(using: .utf8)!

        let result = ApifyAdapter.parse(json, since: since, until: until)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.attributionID == "account" && $0.attributionKind == .workspace && $0.model == nil })
        #expect(records.contains { $0.amountUSD == Decimal(string: "1.500000") })
        #expect(records.contains { $0.amountUSD == Decimal(string: "2.250000") })
    }

    @Test("days outside the requested since/until window are excluded")
    func filtersDaysOutsideWindow() {
        let json = """
        {"data": {"dailyServiceUsages": [
          {"date": "1969-01-01T00:00:00.000Z", "totalUsageCreditsUsd": 5.0}
        ]}}
        """.data(using: .utf8)!

        let result = ApifyAdapter.parse(json, since: since, until: until)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.isEmpty)
    }

    @Test("negative cost surfaces parseError")
    func negativeCostIsParseError() {
        let json = """
        {"data": {"dailyServiceUsages": [
          {"date": "2026-07-01T00:00:00.000Z", "totalUsageCreditsUsd": -1.0}
        ]}}
        """.data(using: .utf8)!

        let result = ApifyAdapter.parse(json, since: since, until: until)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("malformed date surfaces parseError")
    func malformedDateIsParseError() {
        let json = """
        {"data": {"dailyServiceUsages": [
          {"date": "not-a-date", "totalUsageCreditsUsd": 1.0}
        ]}}
        """.data(using: .utf8)!

        let result = ApifyAdapter.parse(json, since: since, until: until)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("missing required field surfaces parseError, not a crash")
    func missingRequiredFieldIsParseError() {
        let json = "{}".data(using: .utf8)!
        let result = ApifyAdapter.parse(json, since: since, until: until)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("401 response classifies as authError")
    func unauthorizedClassifiesAsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let adapter = ApifyAdapter(httpClient: client)
        let result = await adapter.fetchSpend(adminKey: "bad-key", since: since, until: until)
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }
}

@Suite("ApifyBalanceFetcher")
struct ApifyBalanceFetcherTests {
    @Test("computes remaining as maxMonthlyUsageUsd minus monthlyUsageUsd")
    func computesRemaining() {
        let json = """
        {"data": {"limits": {"maxMonthlyUsageUsd": 300}, "current": {"monthlyUsageUsd": 43}}}
        """.data(using: .utf8)!

        let result = ApifyBalanceFetcher.parse(json)
        guard case .success(let balance) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(balance == Decimal(string: "257.000000"))
    }

    @Test("missing required field surfaces parseError, not a fabricated $0")
    func missingFieldIsParseError() {
        let json = """
        {"data": {"limits": {"maxMonthlyUsageUsd": 300}}}
        """.data(using: .utf8)!

        let result = ApifyBalanceFetcher.parse(json)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("401 response classifies as authError")
    func unauthorizedIsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let fetcher = ApifyBalanceFetcher(httpClient: client)
        let result = await fetcher.fetchBalance(adminKey: "bad-key")
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }
}
