import Foundation
import Testing
@testable import APIFollow

@Suite("SpendStore")
struct SpendStoreTests {
    static func makeStore() throws -> SpendStore {
        try SpendStore(inMemory: ())
    }

    static func record(
        provider: Provider = .anthropic,
        attributionID: String = "wrkspc_default",
        attributionKind: AttributionKind = .workspace,
        model: String? = "claude-opus-4-8",
        day: Date,
        amount: Decimal,
        polledAt: Date
    ) -> SpendRecord {
        SpendRecord(
            provider: provider,
            attributionID: attributionID,
            attributionKind: attributionKind,
            model: model,
            day: day,
            amountUSD: amount,
            polledAt: polledAt
        )
    }

    @Test("write then latestPerAttribution round-trips a record")
    func writeAndReadLatest() throws {
        let store = try Self.makeStore()
        let today = Date()
        let record = Self.record(day: today, amount: 12.34, polledAt: today)

        try store.write([record])
        let latest = try store.latestPerAttribution(for: .anthropic)

        #expect(latest.count == 1)
        #expect(latest.first?.amountUSD == 12.34)
    }

    @Test("latestPerAttribution returns only the most recent poll, not every poll")
    func latestPerAttributionDeduplicates() throws {
        let store = try Self.makeStore()
        let today = Date()
        let earlierPoll = today.addingTimeInterval(-600)

        try store.write([Self.record(day: today, amount: 10.00, polledAt: earlierPoll)])
        try store.write([Self.record(day: today, amount: 15.00, polledAt: today)])

        let latest = try store.latestPerAttribution(for: .anthropic)
        #expect(latest.count == 1)
        #expect(latest.first?.amountUSD == 15.00)
    }

    @Test("monthToDateTotal sums the latest poll per day, not every poll (no double-counting)")
    func monthToDateTotalDoesNotDoubleCount() throws {
        let store = try Self.makeStore()
        let now = Date()

        // Simulate 3 re-polls of the SAME day, each returning a growing
        // cumulative total (as a real provider would through the day).
        try store.write([Self.record(day: now, amount: 1.00, polledAt: now.addingTimeInterval(-600))])
        try store.write([Self.record(day: now, amount: 2.50, polledAt: now.addingTimeInterval(-300))])
        try store.write([Self.record(day: now, amount: 4.00, polledAt: now)])

        let total = try store.monthToDateTotal(providers: [.anthropic], now: now)

        // Must be 4.00 (the latest poll's value), NOT 7.50 (the naive sum
        // of all three polls) — this is the overcounting bug this test
        // exists to catch.
        #expect(total == 4.00)
    }

    @Test("monthToDateTotal sums across multiple providers without dropping any")
    func monthToDateTotalSumsAcrossProviders() throws {
        let store = try Self.makeStore()
        let now = Date()

        try store.write([Self.record(provider: .anthropic, attributionID: "wrkspc_1", day: now, amount: 10.00, polledAt: now)])
        try store.write([Self.record(provider: .openai, attributionID: "key_1", attributionKind: .apiKey, day: now, amount: 5.50, polledAt: now)])

        let total = try store.monthToDateTotal(providers: [.anthropic, .openai], now: now)
        #expect(total == 15.50)
    }

    @Test("monthToDateTotal excludes days before the start of the month")
    func monthToDateTotalExcludesPriorMonth() throws {
        let store = try Self.makeStore()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 12))!
        let lastMonth = calendar.date(from: DateComponents(year: 2026, month: 6, day: 28, hour: 12))!

        try store.write([Self.record(day: lastMonth, amount: 100.00, polledAt: lastMonth)])
        try store.write([Self.record(day: now, amount: 3.00, polledAt: now)])

        let total = try store.monthToDateTotal(providers: [.anthropic], now: now)
        #expect(total == 3.00)
    }

    @Test("rollupOldEntries moves old raw polls into daily_aggregates and deletes the raw rows")
    func rollupMovesOldEntries() throws {
        let store = try Self.makeStore()
        let now = Date()
        let oldDay = Calendar(identifier: .gregorian).date(byAdding: .day, value: -45, to: now)!

        try store.write([Self.record(day: oldDay, amount: 7.77, polledAt: oldDay)])
        try store.write([Self.record(day: now, amount: 1.00, polledAt: now)])

        try store.rollupOldEntries(now: now)

        // Old data still readable via the dashboard query (spend), now
        // sourced from daily_aggregates instead of raw_polls.
        let history = try store.spend(for: .anthropic, from: oldDay.addingTimeInterval(-86400), to: now)
        let oldRecord = history.first { $0.amountUSD == 7.77 }
        #expect(oldRecord != nil)

        // Recent data (within retention) is untouched and still in raw_polls.
        let recent = try store.latestPerAttribution(for: .anthropic)
        #expect(recent.contains { $0.amountUSD == 1.00 })
    }

    @Test("rollupOldEntries keeps only the latest value per day when rolling up")
    func rollupKeepsLatestValuePerDay() throws {
        let store = try Self.makeStore()
        let now = Date()
        let oldDay = Calendar(identifier: .gregorian).date(byAdding: .day, value: -45, to: now)!

        try store.write([Self.record(day: oldDay, amount: 2.00, polledAt: oldDay.addingTimeInterval(-600))])
        try store.write([Self.record(day: oldDay, amount: 5.00, polledAt: oldDay)])

        try store.rollupOldEntries(now: now)

        let history = try store.spend(for: .anthropic, from: oldDay.addingTimeInterval(-86400), to: oldDay.addingTimeInterval(86400))
        #expect(history.count == 1)
        #expect(history.first?.amountUSD == 5.00)
    }
}
