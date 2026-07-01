import SwiftUI

/// T7: the expandable dashboard (day/month/provider breakdown), opened
/// from the menu bar popover as a separate `Window` scene rather than
/// crammed into the `.window`-style `MenuBarExtra` popover itself — a
/// real window gets resizing, a title bar, and doesn't fight the
/// popover's compact layout.
struct DashboardView: View {
    let store: SpendStore
    let providers: [Provider]

    @State private var totalsByProvider: [Provider: [(day: Date, amount: Decimal)]] = [:]
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Spend by day")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Refresh") { Task { await load() } }
                    .disabled(isLoading)
            }
            .padding()

            Divider()

            if totalsByProvider.values.allSatisfy({ $0.isEmpty }) {
                VStack {
                    Spacer()
                    Text(isLoading ? "Loading…" : "No spend data yet — configure a provider key in the menu bar first.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(providers, id: \.self) { provider in
                        let totals = totalsByProvider[provider] ?? []
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
                                HStack {
                                    Text("Total")
                                        .bold()
                                    Spacer()
                                    Text(Self.formatAmount(totals.reduce(0) { $0 + $1.amount }))
                                        .bold()
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }

            if providers.contains(.openrouter) {
                Divider()
                Text("Note: OpenRouter shows a single monthly figure only (the account-self-service endpoint doesn't expose a day-by-day history) — not a daily breakdown like Anthropic/OpenAI.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task {
            await load()
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        guard let from = calendar.date(byAdding: .day, value: -60, to: now) else { return }

        var results: [Provider: [(day: Date, amount: Decimal)]] = [:]
        for provider in providers {
            results[provider] = (try? store.dailyTotals(for: provider, from: from, to: now)) ?? []
        }
        totalsByProvider = results
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
