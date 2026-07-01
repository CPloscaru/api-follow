import SwiftUI

/// D4: `.window` style content, not `.menu` — avoids the known SwiftUI
/// bug (FB13683950/FB13683957) where `.menu` style doesn't reliably
/// re-render on open. Full custom-view control here also matches D9's
/// in-memory snapshot read pattern (no disk hit on render).
struct MenuBarView: View {
    @ObservedObject var snapshot: SpendSnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline

            Divider()

            ForEach(Provider.allCases, id: \.self) { provider in
                providerRow(provider)
            }

            Divider()

            if let lastRefreshedAt = snapshot.lastRefreshedAt {
                Text("As of \(lastRefreshedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private var headline: some View {
        HStack {
            Image(systemName: snapshot.overallReliability.systemImageName)
                .foregroundStyle(color(for: snapshot.overallReliability))
            Text(formattedTotal)
                .font(.title2)
                .bold()
            Spacer()
            Text("MTD")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        let status = snapshot.statuses[provider] ?? .staleTransient(lastPolledAt: nil)
        return HStack {
            Text(providerLabel(provider))
            Spacer()
            Text(statusLabel(status))
                .font(.caption)
                .foregroundStyle(statusColor(status))
        }
    }

    private var formattedTotal: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: snapshot.monthToDateTotal as NSDecimalNumber) ?? "$0.00"
    }

    private func providerLabel(_ provider: Provider) -> String {
        switch provider {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        }
    }

    /// D6: four distinct "not current" states get distinct labels, not a
    /// single generic "stale" string — auth-error and parse-error need
    /// to visually read as "needs your attention", not "syncing".
    private func statusLabel(_ status: ProviderStatus) -> String {
        switch status {
        case .ok:
            return "OK"
        case .staleTransient:
            return "Syncing…"
        case .staleRateLimited:
            return "Rate limited"
        case .staleAuthError:
            return "Key needs renewal"
        case .staleParseError:
            return "Needs attention"
        }
    }

    private func statusColor(_ status: ProviderStatus) -> Color {
        status.needsAttention ? .red : (status.isStale ? .orange : .secondary)
    }

    private func color(for glyph: SpendSnapshotStore.ReliabilityGlyph) -> Color {
        switch glyph {
        case .ok: return .green
        case .syncing: return .orange
        case .needsAttention: return .red
        }
    }
}
