import SwiftUI

/// T7: the expandable dashboard (day/month/model breakdown), opened from
/// the menu bar popover as a separate `Window` scene rather than crammed
/// into the `.window`-style `MenuBarExtra` popover itself — a real
/// window gets resizing, a title bar, and doesn't fight the popover's
/// compact layout.
struct DashboardView: View {
    let store: SpendStore
    let providers: [Provider]

    @State private var dailyByProvider: [Provider: [(day: Date, amount: Decimal)]] = [:]
    @State private var modelBreakdownByProvider: [Provider: [SpendStore.ModelBreakdown]] = [:]
    @State private var isLoading = false
    @State private var viewMode: ViewMode = .byDay

    enum ViewMode: String, CaseIterable {
        case byDay = "By Day"
        case byModel = "By Model"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Spend")
                    .font(.title2)
                    .bold()
                Spacer()
                Picker("", selection: $viewMode) {
                    ForEach(ViewMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                Button("Refresh") { Task { await load() } }
                    .disabled(isLoading)
            }
            .padding()

            Divider()

            if isEverythingEmpty {
                VStack {
                    Spacer()
                    Text(isLoading ? "Loading…" : "No spend data yet — configure a provider key in the menu bar first.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .byDay {
                byDayList
            } else {
                byModelList
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .task {
            await load()
        }
    }

    private var isEverythingEmpty: Bool {
        dailyByProvider.values.allSatisfy(\.isEmpty) && modelBreakdownByProvider.values.allSatisfy(\.isEmpty)
    }

    private var byDayList: some View {
        List {
            ForEach(providers, id: \.self) { provider in
                let totals = dailyByProvider[provider] ?? []
                if !totals.isEmpty {
                    Section(MenuBarView.providerLabel(provider)) {
                        ForEach(totals, id: \.day) { entry in
                            HStack {
                                Text(entry.day.formatted(date: .abbreviated, time: .omitted))
                                Spacer()
                                Text(Self.formatAmount(entry.amount))
                                    .monospacedDigit()
                            }
                        }
                        totalRow(totals.reduce(0) { $0 + $1.amount })
                    }
                }
            }
        }
    }

    private var byModelList: some View {
        List {
            ForEach(providers, id: \.self) { provider in
                let breakdown = modelBreakdownByProvider[provider] ?? []
                if !breakdown.isEmpty {
                    Section(MenuBarView.providerLabel(provider)) {
                        ForEach(breakdown, id: \.model) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.model)
                                        .bold()
                                    Spacer()
                                    Text(Self.formatAmount(entry.amountUSD))
                                        .monospacedDigit()
                                }
                                Text(tokenSummary(entry))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        totalRow(breakdown.reduce(0) { $0 + $1.amountUSD })
                    }
                } else if dailyByProvider[provider]?.isEmpty == false {
                    Section(MenuBarView.providerLabel(provider)) {
                        Text("No per-model breakdown available for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tokenSummary(_ entry: SpendStore.ModelBreakdown) -> String {
        "\(entry.requests) request\(entry.requests == 1 ? "" : "s") · "
            + "\(entry.promptTokens) prompt · \(entry.completionTokens) completion"
            + (entry.reasoningTokens > 0 ? " · \(entry.reasoningTokens) reasoning" : "")
            + " tokens"
    }

    private func totalRow(_ total: Decimal) -> some View {
        HStack {
            Text("Total")
                .bold()
            Spacer()
            Text(Self.formatAmount(total))
                .bold()
                .monospacedDigit()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        guard let from = calendar.date(byAdding: .day, value: -60, to: now) else { return }

        var daily: [Provider: [(day: Date, amount: Decimal)]] = [:]
        var models: [Provider: [SpendStore.ModelBreakdown]] = [:]
        for provider in providers {
            daily[provider] = (try? store.dailyTotals(for: provider, from: from, to: now)) ?? []
            models[provider] = (try? store.modelBreakdown(for: provider, from: from, to: now)) ?? []
        }
        dailyByProvider = daily
        modelBreakdownByProvider = models
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
