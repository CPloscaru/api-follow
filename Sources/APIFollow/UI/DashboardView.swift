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
    @ObservedObject var snapshot: SpendSnapshotStore

    @State private var selectedProvider: Provider
    @State private var records: [SpendRecord] = []
    @State private var isLoading = false
    @State private var rangeDays = 30

    // One hovered-day slot per chart (not shared) — charts scroll
    // independently and each has its own day set/series shape, so a
    // single shared slot would show the wrong chart's tooltip if two
    // were hovered in quick succession.
    @State private var hoveredSpendByModelDay: Date?
    @State private var hoveredRequestsDay: Date?
    @State private var hoveredTokenDay: Date?
    @State private var hoveredUsageTypeDay: Date?
    @State private var hoveredTotalSpendDay: Date?

    init(store: SpendStore, providers: [Provider], snapshot: SpendSnapshotStore) {
        self.store = store
        self.providers = providers
        self.snapshot = snapshot
        _selectedProvider = State(initialValue: providers.first ?? .anthropic)
    }

    private static let modelPalette: [Color] = [
        .blue, .purple, .pink, .orange, .teal, .yellow, .green, .indigo, .red, .mint,
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if isLoading && records.isEmpty {
                    loadingState
                } else {
                    // Structure is always shown once the first load
                    // completes — same as OpenRouter's own Activity page,
                    // which keeps every card/chart visible at zero rather
                    // than collapsing to a blank state when a window has
                    // no activity. Whether a SECTION exists at all is a
                    // provider-capability question ("does this provider's
                    // API expose per-model/BYOK data at all"), not a
                    // data-presence question ("is there data right now").
                    kpiRow

                    if providerSupportsSpendByModel {
                        chartCard(title: "Usage by model", subtitle: "Spend per day, by model") {
                            spendByModelChart
                        }
                        chartCard(title: "Top endpoints by spend", subtitle: "Ranked over the last \(rangeDays) days") {
                            topEndpointsChart
                        }
                    } else {
                        chartCard(title: "Spend by day", subtitle: "No per-model breakdown for this provider") {
                            totalSpendChart
                        }
                    }

                    if providerSupportsRequestsByModel {
                        chartCard(title: "Request volume by model", subtitle: "Requests per day, by model") {
                            requestsByModelChart
                        }
                    }

                    if providerSupportsTokenBreakdown {
                        chartCard(title: "Token breakdown", subtitle: "Prompt / completion / reasoning tokens per day") {
                            tokenBreakdownChart
                        }
                    }

                    if providerSupportsByokBreakdown {
                        chartCard(title: "Usage type", subtitle: "BYOK vs. OpenRouter-billed spend per day") {
                            usageTypeChart
                        }
                    }

                    if records.isEmpty {
                        Text("No activity for \(MenuBarView.providerLabel(selectedProvider)) in the last \(rangeDays) days — cards and charts above are showing their zero/empty state, not an error.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            if let balance = snapshot.balances[selectedProvider] {
                kpiCard(title: "Credits remaining", value: Self.formatAmount(balance))
            }
            // Requests/Token volume gated the same way as the charts —
            // showing "0 Requests" for a provider that never tracks
            // request counts (fal.ai) would read as "zero requests
            // happened", not "this app doesn't measure that here".
            if providerSupportsRequestsByModel {
                kpiCard(title: "Requests", value: "\(totalRequests)")
            }
            if providerSupportsTokenBreakdown {
                kpiCard(title: "Token volume", value: Self.formatCompact(totalTokens))
            }
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
        let days = spendByModelSeries.map(\.day)
        return Chart(spendByModelSeries, id: \.id) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Spend", entry.amount)
            )
            .foregroundStyle(color(for: entry.model))
            .position(by: .value("Model", entry.model))
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 220)
        .hoverTooltip(days: days, selection: $hoveredSpendByModelDay) { day in
            let entries = spendByModelSeries.filter { Self.dayKey($0.day) == Self.dayKey(day) }
            let rows = entries.map { TooltipRow(label: $0.model, value: Self.formatAmount($0.amount), color: color(for: $0.model)) }
            return TooltipContent(dateLabel: Self.dayLabel(day), rows: rows, total: Self.formatAmount(entries.reduce(0) { $0 + $1.amount }))
        }
    }

    private var requestsByModelChart: some View {
        let days = requestsByModelSeries.map(\.day)
        return Chart(requestsByModelSeries, id: \.id) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Requests", entry.requests)
            )
            .foregroundStyle(color(for: entry.model))
            .position(by: .value("Model", entry.model))
        }
        .chartLegend(position: .bottom, spacing: 8)
        .frame(height: 220)
        .hoverTooltip(days: days, selection: $hoveredRequestsDay) { day in
            let entries = requestsByModelSeries.filter { Self.dayKey($0.day) == Self.dayKey(day) }
            let rows = entries.map { TooltipRow(label: $0.model, value: "\($0.requests)", color: color(for: $0.model)) }
            return TooltipContent(dateLabel: Self.dayLabel(day), rows: rows, total: "\(entries.reduce(0) { $0 + $1.requests })")
        }
    }

    private var tokenBreakdownChart: some View {
        let days = tokenBreakdownSeries.map(\.day)
        return Chart(tokenBreakdownSeries) { entry in
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
        .hoverTooltip(days: days, selection: $hoveredTokenDay) { day in
            let entries = tokenBreakdownSeries.filter { Self.dayKey($0.day) == Self.dayKey(day) }
            let tokenColor: (String) -> Color = { $0 == "Prompt" ? .blue : ($0 == "Completion" ? .purple : .pink) }
            let rows = entries.map { TooltipRow(label: $0.kind, value: Self.formatCompact($0.count), color: tokenColor($0.kind)) }
            return TooltipContent(dateLabel: Self.dayLabel(day), rows: rows, total: Self.formatCompact(entries.reduce(0) { $0 + $1.count }))
        }
    }

    private var usageTypeChart: some View {
        let days = usageTypeSeries.map(\.day)
        return Chart(usageTypeSeries) { entry in
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
        .hoverTooltip(days: days, selection: $hoveredUsageTypeDay) { day in
            let entries = usageTypeSeries.filter { Self.dayKey($0.day) == Self.dayKey(day) }
            let rows = entries.map { TooltipRow(label: $0.kind, value: Self.formatAmount($0.amount), color: $0.kind == "BYOK" ? .yellow : .purple) }
            return TooltipContent(dateLabel: Self.dayLabel(day), rows: rows, total: nil)
        }
    }

    private var totalSpendChart: some View {
        let days = dailyTotalsSeries.map(\.day)
        return Chart(dailyTotalsSeries, id: \.day) { entry in
            BarMark(
                x: .value("Day", entry.day, unit: .day),
                y: .value("Spend", entry.amount)
            )
            .foregroundStyle(.blue)
        }
        .frame(height: 220)
        .hoverTooltip(days: days, selection: $hoveredTotalSpendDay) { day in
            let amount = dailyTotalsSeries.first { Self.dayKey($0.day) == Self.dayKey(day) }?.amount ?? 0
            return TooltipContent(dateLabel: Self.dayLabel(day), rows: [TooltipRow(label: "Spend", value: Self.formatAmount(amount), color: .blue)], total: nil)
        }
    }

    /// Ranked horizontal bars, one per model, summed across the whole
    /// selected range — matches fal.ai's own "Top endpoints by spend"
    /// card. Built entirely from data already fetched for the per-day
    /// chart above (no new API calls, no new fields).
    private var topEndpointsChart: some View {
        Chart(topEndpointsSeries) { entry in
            BarMark(
                x: .value("Spend", entry.amount),
                y: .value("Model", entry.model)
            )
            .foregroundStyle(color(for: entry.model))
            .annotation(position: .trailing) {
                Text(Self.formatAmount(entry.amount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                if let model = value.as(String.self) {
                    AxisValueLabel {
                        Text(model)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(height: CGFloat(topEndpointsSeries.count) * 32 + 20)
    }

    // MARK: - Empty / unavailable

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Loading…")
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

    /// One row inside a hover tooltip — a colored dot, a label (model
    /// name / token kind / usage kind), and a formatted value. Mirrors
    /// fal.ai's own Activity page tooltip (date header, per-series
    /// breakdown, total) since that's the reference the user is
    /// comparing against.
    fileprivate struct TooltipRow: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let color: Color
    }

    fileprivate struct TooltipContent {
        let dateLabel: String
        let rows: [TooltipRow]
        let total: String?
    }

    /// Which chart sections a PROVIDER can support — a capability
    /// question, not "does data exist right now". A quiet account still
    /// gets these sections (rendered empty), because the underlying API
    /// exposes the dimension; a provider whose API genuinely doesn't
    /// have it never gets the section, regardless of how much data is
    /// polled. Split into separate flags (not one blanket
    /// "supports model breakdown") because fal.ai has real per-model
    /// SPEND data (`endpoint_id` in its Usage API) but NOT request
    /// counts or token counts — `quantity`/`unit` there means things
    /// like "4 images", deliberately not mapped into `requests` (see
    /// FalAdapter's doc comment) since that would misrepresent what
    /// the number means.
    private var providerSupportsSpendByModel: Bool {
        selectedProvider == .openrouter || selectedProvider == .fal
    }

    private var providerSupportsRequestsByModel: Bool {
        selectedProvider == .openrouter
    }

    private var providerSupportsTokenBreakdown: Bool {
        selectedProvider == .openrouter
    }

    private var providerSupportsByokBreakdown: Bool {
        selectedProvider == .openrouter
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

    private struct TopEndpointEntry: Identifiable {
        var id: String { model }
        var model: String
        var amount: Decimal
    }

    private var topEndpointsSeries: [TopEndpointEntry] {
        var byModel: [String: Decimal] = [:]
        for record in records {
            guard let model = record.model else { continue }
            byModel[model, default: 0] += record.amountUSD
        }
        return byModel
            .map { TopEndpointEntry(model: $0.key, amount: $0.value) }
            .sorted { $0.amount > $1.amount }
            .prefix(8)
            .reversed() // BarMark on a y-axis category draws bottom-up — reverse so highest spend renders at the top, matching the reference's top-to-bottom ranking
            .map { $0 }
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

    fileprivate static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
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

/// Mouse-hover tooltips on bar charts — direct answer to "I can hover
/// over fal.ai's own chart and see a breakdown, can't we show that
/// too?". `.onContinuousHover` (native mouse tracking, not a drag
/// gesture — this is a desktop app, not touch) finds the nearest day
/// under the cursor via the chart's own x-scale, snaps to the closest
/// day actually present in that chart's data (bars are exactly one day
/// wide, so any x within a bar's width should resolve to that bar's
/// day), and renders a floating card built by the caller's `content`
/// closure. Each chart supplies its own tooltip content since the
/// underlying series shape differs (model breakdown vs. token kind vs.
/// plain daily total) — this extension only owns hit-testing and
/// rendering, not what the numbers mean.
private extension View {
    func hoverTooltip(
        days: [Date],
        selection: Binding<Date?>,
        @ViewBuilder content: @escaping (Date) -> DashboardView.TooltipContent
    ) -> some View {
        chartOverlay { proxy in
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let plotFrame = geometry[proxy.plotAreaFrame]
                                let relativeX = location.x - plotFrame.origin.x
                                guard let hoveredDate: Date = proxy.value(atX: relativeX),
                                      let nearest = days.min(by: {
                                          abs($0.timeIntervalSince(hoveredDate)) < abs($1.timeIntervalSince(hoveredDate))
                                      })
                                else {
                                    selection.wrappedValue = nil
                                    return
                                }
                                selection.wrappedValue = nearest
                            case .ended:
                                selection.wrappedValue = nil
                            }
                        }

                    if let day = selection.wrappedValue {
                        let tooltip = content(day)
                        let plotFrame = geometry[proxy.plotAreaFrame]
                        let xPosition = (proxy.position(forX: day) ?? 0) + plotFrame.origin.x
                        DashboardTooltipCard(content: tooltip)
                            .position(x: min(max(xPosition, 80), geometry.size.width - 80), y: 60)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

private struct DashboardTooltipCard: View {
    let content: DashboardView.TooltipContent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(content.dateLabel)
                .font(.caption.bold())
            ForEach(content.rows) { row in
                HStack(spacing: 6) {
                    Circle().fill(row.color).frame(width: 6, height: 6)
                    Text(row.label)
                        .font(.caption2)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(row.value)
                        .font(.caption2.monospacedDigit())
                }
            }
            if let total = content.total {
                Divider()
                HStack {
                    Text("Total").font(.caption2.bold())
                    Spacer(minLength: 12)
                    Text(total).font(.caption2.bold().monospacedDigit())
                }
            }
        }
        .padding(8)
        .frame(width: 200, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.32), lineWidth: 1)
        )
        .shadow(radius: 6)
    }
}
