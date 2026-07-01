import SwiftUI
import Charts

/// T7: the expandable dashboard, opened from the menu bar popover as a
/// separate `Window` scene. Modeled on OpenRouter's own Activity page
/// layout (KPI cards + stacked charts) since that's the bar the user is
/// comparing against — same visual structure, but only built from data
/// this app can actually verify against the real API response shape
/// (D8's strict-parsing philosophy applies to the UI too: don't show a
/// number or chart for something we don't actually have).
///
/// Honest gaps vs. OpenRouter's own page, not built because the
/// `/api/v1/activity` response doesn't expose them: **Cache hit rate**,
/// **Prompt token caching** (cached/uncached split), **Top API Keys**,
/// **Top Apps**. Faking these would violate the same "never show a
/// number we can't back up" principle behind D8/D12.
struct DashboardView: View {
    let store: SpendStore
    let providers: [Provider]

    @State private var selectedProvider: Provider
    @State private var records: [SpendRecord] = []
    @State private var isLoading = false
    @State private var rangeDays = 30

    init(store: SpendStore, providers: [Provider]) {
        self.store = store
        self.providers = providers
        _selectedProvider = State(initialValue: providers.first ?? .anthropic)
    }

    private static let modelPalette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .yellow, .green, .indigo, .red, .mint,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if records.isEmpty {
                    emptyState
                } else {
                    kpiRow

                    if hasModelData {
                        chartCard(title: "Usage by model", subtitle: "Spend per day, by model") {
                            spendByModelChart
                        }
                        chartCard(title: "Request volume by model", subtitle: "Requests per day, by model") {
                            requestsByModelChart
                        }
                        chartCard(title: "Token breakdown", subtitle: "Prompt / completion / reasoning tokens per day") {
                            tokenBreakdownChart
                        }
                    }

                    if hasByokData {
                        chartCard(title: "Usage type", subtitle: "BYOK vs. OpenRouter-billed spend per day") {
                            usageTypeChart
                        }
                    }

                    if !hasModelData {
                        chartCard(title: "Spend by day", subtitle: "No per-model breakdown for this provider") {
                            totalSpendChart
                        }
                    }

                    unavailableNote
                }
            }
            .padding(20)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .frame(minWidth: 560, minHeight: 520)
        .task { await load() }
        // Single-closure form (not the macOS 14+ two-param variant) —
        // keeps this at the design doc's macOS 13 floor, same reasoning
        // as SpendSnapshotStore's ObservableObject-over-@Observable choice.
        .onChange(of: selectedProvider) { _ in Task { await load() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .font(.largeTitle)
                    .bold()
                Text("Your usage across \(MenuBarView.providerLabel(selectedProvider))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Provider", selection: $selectedProvider) {
                ForEach(providers, id: \.self) { provider in
                    Text(MenuBarView.providerLabel(provider)).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
    }

    // MARK: - KPIs

    private var kpiRow: some View {
        HStack(spacing: 12) {
            kpiCard(title: "Total spend", value: Self.formatAmount(totalSpend))
            kpiCard(title: "Requests", value: "\(totalRequests)")
            kpiCard(title: "Token volume", value: Self.formatCompact(totalTokens))
        }
    }

    private func kpiCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title)
                .bold()
                .monospacedDigit()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Charts

    private var spendByModelChart: some View {
        Chart(spendByModelSeries, id: \.id) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Spend", entry.amount)
            )
            .foregroundStyle(color(for: entry.model))
            .position(by: .value("Model", entry.model))
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 220)
    }

    private var requestsByModelChart: some View {
        Chart(requestsByModelSeries, id: \.id) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Requests", entry.requests)
            )
            .foregroundStyle(color(for: entry.model))
            .position(by: .value("Model", entry.model))
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 220)
    }

    private var tokenBreakdownChart: some View {
        Chart(tokenBreakdownSeries) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Tokens", entry.count)
            )
            .foregroundStyle(by: .value("Type", entry.kind))
            .position(by: .value("Type", entry.kind))
        }
        .chartForegroundStyleScale([
            "Prompt": Color.blue, "Completion": Color.purple, "Reasoning": Color.pink,
        ])
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 220)
    }

    private var usageTypeChart: some View {
        Chart(usageTypeSeries) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Spend", entry.amount)
            )
            .foregroundStyle(by: .value("Type", entry.kind))
            .position(by: .value("Type", entry.kind))
        }
        .chartForegroundStyleScale([
            "BYOK": Color.yellow, "OpenRouter Spend": Color.purple,
        ])
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 220)
    }

    private var totalSpendChart: some View {
        Chart(dailyTotalsSeries, id: \.day) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Spend", entry.amount)
            )
            .foregroundStyle(.blue)
        }
        .frame(height: 220)
    }

    // MARK: - Empty / unavailable

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(isLoading ? "Loading…" : "No spend data yet for \(MenuBarView.providerLabel(selectedProvider)).")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    private var unavailableNote: some View {
        Text("Not shown (unavailable from this provider's API): cache hit rate, prompt token caching (cached/uncached split), top API keys, top apps. This app never shows a figure it can't back up with a real response field.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func chartCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(white: 0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.18), lineWidth: 1))
    }

    // MARK: - Derived series

    private struct ModelDayEntry: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(model)" }
        var day: Date
        var model: String
        var amount: Decimal = 0
        var requests: Int = 0
    }

    private struct TokenEntry: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
        var day: Date
        var kind: String
        var count: Int
    }

    private struct UsageTypeEntry: Identifiable {
        var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
        var day: Date
        var kind: String
        var amount: Decimal
    }

    private var hasModelData: Bool {
        records.contains { $0.model != nil }
    }

    private var hasByokData: Bool {
        records.contains { $0.byokUsageUSD != nil }
    }

    private var totalSpend: Decimal {
        records.reduce(0) { $0 + $1.amountUSD }
    }

    private var totalRequests: Int {
        records.reduce(0) { $0 + ($1.requests ?? 0) }
    }

    private var totalTokens: Int {
        records.reduce(0) { $0 + ($1.promptTokens ?? 0) + ($1.completionTokens ?? 0) + ($1.reasoningTokens ?? 0) }
    }

    private var spendByModelSeries: [ModelDayEntry] {
        var byKey: [String: ModelDayEntry] = [:]
        for record in records {
            guard let model = record.model else { continue }
            let key = "\(Self.dayKey(record.day))-\(model)"
            var entry = byKey[key] ?? ModelDayEntry(day: record.day, model: model)
            entry.amount += record.amountUSD
            byKey[key] = entry
        }
        return byKey.values.sorted { $0.day < $1.day }
    }

    private var requestsByModelSeries: [ModelDayEntry] {
        var byKey: [String: ModelDayEntry] = [:]
        for record in records {
            guard let model = record.model else { continue }
            let key = "\(Self.dayKey(record.day))-\(model)"
            var entry = byKey[key] ?? ModelDayEntry(day: record.day, model: model)
            entry.requests += record.requests ?? 0
            byKey[key] = entry
        }
        return byKey.values.sorted { $0.day < $1.day }
    }

    private var tokenBreakdownSeries: [TokenEntry] {
        var byDay: [Date: (prompt: Int, completion: Int, reasoning: Int)] = [:]
        for record in records {
            var totals = byDay[record.day] ?? (0, 0, 0)
            totals.prompt += record.promptTokens ?? 0
            totals.completion += record.completionTokens ?? 0
            totals.reasoning += record.reasoningTokens ?? 0
            byDay[record.day] = totals
        }
        return byDay.flatMap { day, totals in
            [
                TokenEntry(day: day, kind: "Prompt", count: totals.prompt),
                TokenEntry(day: day, kind: "Completion", count: totals.completion),
                TokenEntry(day: day, kind: "Reasoning", count: totals.reasoning),
            ]
        }.sorted { $0.day < $1.day }
    }

    private var usageTypeSeries: [UsageTypeEntry] {
        var byDay: [Date: (byok: Decimal, spend: Decimal)] = [:]
        for record in records {
            var totals = byDay[record.day] ?? (0, 0)
            totals.byok += record.byokUsageUSD ?? 0
            totals.spend += record.amountUSD
            byDay[record.day] = totals
        }
        return byDay.flatMap { day, totals in
            [
                UsageTypeEntry(day: day, kind: "BYOK", amount: totals.byok),
                UsageTypeEntry(day: day, kind: "OpenRouter Spend", amount: totals.spend),
            ]
        }.sorted { $0.day < $1.day }
    }

    private var dailyTotalsSeries: [(day: Date, amount: Decimal)] {
        var byDay: [Date: Decimal] = [:]
        for record in records {
            byDay[record.day, default: 0] += record.amountUSD
        }
        return byDay.map { ($0.key, $0.value) }.sorted { $0.day < $1.day }
    }

    private func color(for model: String) -> Color {
        let index = abs(model.hashValue) % Self.modelPalette.count
        return Self.modelPalette[index]
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        guard let from = calendar.date(byAdding: .day, value: -rangeDays, to: now) else { return }

        records = (try? store.dedupedRecords(for: selectedProvider, from: from, to: now)) ?? []
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }

    private static func formatCompact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }
}
