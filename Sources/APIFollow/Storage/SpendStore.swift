import Foundation
import GRDB

/// GRDB-backed persistence. Design doc D5: GRDB chosen over SwiftData for
/// direct SQL control over the aggregation queries this app needs
/// (rollup, grouping by provider+attribution+model+day).
///
/// Two tables:
/// - `raw_polls`: append-only, one row per successful poll. Lets the
///   dashboard show how a day's number evolved as later polls refine it.
/// - `daily_aggregates`: one settled row per (provider, attribution, model,
///   day), upserted during rollup. `raw_polls` older than the retention
///   window get rolled into this table and deleted, so the raw table
///   doesn't grow unbounded (Success Criteria).
/// `@unchecked Sendable`: GRDB's `DatabaseQueue` serializes all access
/// internally (it's a wrapper around a serial dispatch queue), so sharing
/// a `SpendStore` instance across concurrency domains (the poller actor,
/// the UI's snapshot store) is safe even though the compiler can't prove
/// it automatically.
final class SpendStore: @unchecked Sendable {
    static let retentionDays = 30

    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try migrator.migrate(dbQueue)
    }

    /// In-memory database — used by tests so they don't touch disk.
    init(inMemory: Void) throws {
        dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "raw_polls") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("provider", .text).notNull()
                t.column("attribution_id", .text).notNull()
                t.column("attribution_kind", .text).notNull()
                t.column("model", .text)
                t.column("day", .text).notNull() // ISO 8601 date, e.g. "2026-07-01"
                t.column("amount_usd", .text).notNull() // decimal string, exact precision
                t.column("polled_at", .text).notNull() // ISO 8601 datetime
            }
            try db.create(
                index: "idx_raw_polls_lookup",
                on: "raw_polls",
                columns: ["provider", "attribution_id", "day"]
            )

            try db.create(table: "daily_aggregates") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("provider", .text).notNull()
                t.column("attribution_id", .text).notNull()
                t.column("attribution_kind", .text).notNull()
                t.column("model", .text)
                t.column("day", .text).notNull()
                t.column("amount_usd", .text).notNull()
                t.uniqueKey(["provider", "attribution_id", "model", "day"])
            }
            try db.create(
                index: "idx_daily_aggregates_lookup",
                on: "daily_aggregates",
                columns: ["provider", "attribution_id", "day"]
            )
        }

        return migrator
    }

    // MARK: - Write

    /// Appends raw poll results. Called by the poller after a successful,
    /// strictly-parsed fetch (D8) — never called with partial/guessed data.
    func write(_ records: [SpendRecord]) throws {
        try dbQueue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO raw_polls
                            (provider, attribution_id, attribution_kind, model, day, amount_usd, polled_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        record.provider.rawValue,
                        record.attributionID,
                        record.attributionKind.rawValue,
                        record.model,
                        Self.dayString(record.day),
                        "\(record.amountUSD)",
                        Self.dateTimeString(record.polledAt),
                    ]
                )
            }
        }
    }

    // MARK: - Read

    /// The most recent raw_poll row per (provider, attribution, model) —
    /// this is what the in-memory snapshot store (D9) hydrates from on
    /// launch, and what the menu bar's month-to-date total sums (D11/D12:
    /// always the last-known value, regardless of freshness).
    func latestPerAttribution(for provider: Provider) throws -> [SpendRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.* FROM raw_polls r
                    INNER JOIN (
                        SELECT attribution_id, model, MAX(polled_at) AS max_polled_at
                        FROM raw_polls
                        WHERE provider = ?
                        GROUP BY attribution_id, model
                    ) latest
                    ON r.attribution_id = latest.attribution_id
                    AND (r.model IS latest.model)
                    AND r.polled_at = latest.max_polled_at
                    WHERE r.provider = ?
                    """,
                arguments: [provider.rawValue, provider.rawValue]
            )
            return rows.compactMap(Self.record(from:))
        }
    }

    /// Month-to-date total across all providers, summed from each
    /// (attribution, model, day)'s LATEST known value — never silently
    /// drops a provider (D12). Each day's bucket total grows as the day
    /// progresses and gets re-polled every 5 minutes, so this must take
    /// the latest poll per day, not sum every poll — summing every row
    /// would count the same day's cumulative total once per poll and
    /// wildly overstate spend.
    func monthToDateTotal(providers: [Provider], now: Date) throws -> Decimal {
        let monthStart = Self.startOfMonth(for: now)
        let monthStartDay = Self.dayString(monthStart)

        return try dbQueue.read { db in
            var total: Decimal = 0
            for provider in providers {
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT r.amount_usd FROM raw_polls r
                        INNER JOIN (
                            SELECT attribution_id, model, day, MAX(polled_at) AS max_polled_at
                            FROM raw_polls
                            WHERE provider = ? AND day >= ?
                            GROUP BY attribution_id, model, day
                        ) latest
                        ON r.attribution_id = latest.attribution_id
                        AND (r.model IS latest.model)
                        AND r.day = latest.day
                        AND r.polled_at = latest.max_polled_at
                        WHERE r.provider = ?
                        """,
                    arguments: [provider.rawValue, monthStartDay, provider.rawValue]
                )
                for row in rows {
                    if let amountString: String = row["amount_usd"], let amount = Decimal(string: amountString) {
                        total += amount
                    }
                }
            }
            return total
        }
    }

    /// Spend broken down by day/model/attribution for the dashboard,
    /// reading across both raw_polls (recent) and daily_aggregates
    /// (rolled up) so history beyond the retention window still shows.
    func spend(for provider: Provider, from: Date, to: Date) throws -> [SpendRecord] {
        let fromDay = Self.dayString(from)
        let toDay = Self.dayString(to)

        return try dbQueue.read { db in
            let rawRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM raw_polls WHERE provider = ? AND day >= ? AND day <= ?",
                arguments: [provider.rawValue, fromDay, toDay]
            )
            let aggregateRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM daily_aggregates WHERE provider = ? AND day >= ? AND day <= ?",
                arguments: [provider.rawValue, fromDay, toDay]
            )
            return (rawRows + aggregateRows).compactMap(Self.record(from:))
        }
    }

    // MARK: - Retention / rollup

    /// Rolls raw_polls older than `retentionDays` into daily_aggregates
    /// (keeping the latest value per day) and deletes the raw rows, so
    /// the raw table doesn't grow unbounded (Success Criteria).
    func rollupOldEntries(now: Date = Date()) throws {
        guard let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -Self.retentionDays, to: now) else {
            return
        }
        let cutoffDay = Self.dayString(cutoff)

        try dbQueue.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.* FROM raw_polls r
                    INNER JOIN (
                        SELECT provider, attribution_id, model, day, MAX(polled_at) AS max_polled_at
                        FROM raw_polls
                        WHERE day < ?
                        GROUP BY provider, attribution_id, model, day
                    ) latest
                    ON r.provider = latest.provider
                    AND r.attribution_id = latest.attribution_id
                    AND (r.model IS latest.model)
                    AND r.day = latest.day
                    AND r.polled_at = latest.max_polled_at
                    """,
                arguments: [cutoffDay]
            )

            for row in rows {
                guard let record = Self.record(from: row) else { continue }
                try db.execute(
                    sql: """
                        INSERT INTO daily_aggregates
                            (provider, attribution_id, attribution_kind, model, day, amount_usd)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(provider, attribution_id, model, day)
                        DO UPDATE SET amount_usd = excluded.amount_usd
                        """,
                    arguments: [
                        record.provider.rawValue,
                        record.attributionID,
                        record.attributionKind.rawValue,
                        record.model,
                        Self.dayString(record.day),
                        "\(record.amountUSD)",
                    ]
                )
            }

            try db.execute(sql: "DELETE FROM raw_polls WHERE day < ?", arguments: [cutoffDay])
        }
    }

    // MARK: - Helpers

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func dateTimeString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func startOfMonth(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func record(from row: Row) -> SpendRecord? {
        guard
            let providerRaw: String = row["provider"],
            let provider = Provider(rawValue: providerRaw),
            let attributionID: String = row["attribution_id"],
            let attributionKindRaw: String = row["attribution_kind"],
            let attributionKind = AttributionKind(rawValue: attributionKindRaw),
            let dayString: String = row["day"],
            let amountString: String = row["amount_usd"],
            let amount = Decimal(string: amountString)
        else {
            return nil
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")
        guard let day = dayFormatter.date(from: dayString) else { return nil }

        let polledAtString: String? = row["polled_at"]
        let polledAt = polledAtString.flatMap { ISO8601DateFormatter().date(from: $0) } ?? day

        return SpendRecord(
            provider: provider,
            attributionID: attributionID,
            attributionKind: attributionKind,
            model: row["model"],
            day: day,
            amountUSD: amount,
            polledAt: polledAt
        )
    }
}
