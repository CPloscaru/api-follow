import Foundation
import Testing
@testable import APIFollow

@Suite("OpenRouterAdapter")
struct OpenRouterAdapterTests {
    static let fixedNow: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 12))!
    }()

    @Test("parses a well-formed /api/v1/key response, one record for the current month")
    func parsesWellFormedResponse() {
        let json = """
        {
          "data": {
            "usage": 25.5,
            "usage_daily": 2.1,
            "usage_monthly": 25.5,
            "limit": 100,
            "limit_remaining": 74.5,
            "is_free_tier": false,
            "label": "sk-or-v1-abc"
          }
        }
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json, now: Self.fixedNow)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.count == 1)
        #expect(records.first?.amountUSD == Decimal(string: "25.500000"))
        #expect(records.first?.attributionKind == .apiKey)
        #expect(records.first?.attributionID == "sk-or-v1-abc")
    }

    @Test("record is keyed to the start of the month, not the poll day")
    func recordUsesMonthStartAsDay() {
        let json = """
        {"data": {"usage": 1.0, "usage_monthly": 1.0, "label": "k"}}
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json, now: Self.fixedNow)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day], from: records.first!.day)
        #expect(components.year == 2026)
        #expect(components.month == 7)
        #expect(components.day == 1)
    }

    @Test("missing label falls back to 'self', does not crash")
    func missingLabelUsesFallback() {
        let json = """
        {"data": {"usage": 1.0, "usage_monthly": 1.0}}
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json, now: Self.fixedNow)
        guard case .success(let records) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(records.first?.attributionID == "self")
    }

    @Test("negative usage_monthly surfaces parseError, not a silently wrong amount")
    func negativeUsageIsParseError() {
        let json = """
        {"data": {"usage": -1.0, "usage_monthly": -1.0, "label": "k"}}
        """.data(using: .utf8)!

        let result = OpenRouterAdapter.parse(json, now: Self.fixedNow)
        guard case .parseError = result else {
            Issue.record("expected .parseError, got \(result)")
            return
        }
    }

    @Test("missing required field (data.usage_monthly) surfaces parseError, not a crash")
    func missingRequiredFieldIsParseError() {
        let json = "{}".data(using: .utf8)!
        let result = OpenRouterAdapter.parse(json, now: Self.fixedNow)
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

    @Test("repeated polls within the same month overwrite rather than sum (no double-counting)")
    func repeatedPollsWithinSameMonthDoNotAccumulate() throws {
        let store = try SpendStore(inMemory: ())

        let earlierInMonth: Date = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 9))!
        }()

        let json1 = """
        {"data": {"usage": 10.0, "usage_monthly": 10.0, "label": "k"}}
        """.data(using: .utf8)!
        let json2 = """
        {"data": {"usage": 15.0, "usage_monthly": 15.0, "label": "k"}}
        """.data(using: .utf8)!

        guard case .success(let firstPoll) = OpenRouterAdapter.parse(json1, now: earlierInMonth) else {
            Issue.record("expected success"); return
        }
        guard case .success(let secondPoll) = OpenRouterAdapter.parse(json2, now: Self.fixedNow) else {
            Issue.record("expected success"); return
        }

        try store.write(firstPoll)
        try store.write(secondPoll)

        let total = try store.monthToDateTotal(providers: [.openrouter], now: Self.fixedNow)
        // Must be 15.0 (the latest poll's cumulative value), NOT 25.0
        // (the naive sum) — both polls land in the same month-start day
        // bucket, so latest-per-day dedup picks only the newer one.
        #expect(total == 15.0)
    }
}
