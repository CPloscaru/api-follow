import SwiftUI

/// The floating desktop overlay's content — generalized from an
/// earlier Claude-only version per direct user request: shows
/// everything connected (MTD total, each provider's balance/spend,
/// Claude session/weekly), not just Claude. Read-only display — key
/// entry/editing stays in the menu bar popover, this is purely a
/// glanceable summary meant to sit on the desktop.
struct GlobalOverlayView: View {
    @ObservedObject var snapshot: SpendSnapshotStore
    @ObservedObject var claudePlanSnapshot: ClaudePlanSnapshotStore
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            ForEach(snapshot.providers, id: \.self) { provider in
                if snapshot.keysConfigured.contains(provider) {
                    providerRow(provider)
                }
            }

            if claudePlanSnapshot.isAvailable {
                Divider()
                claudeSection
            }
        }
        .padding(14)
        .frame(width: 240)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Image(systemName: snapshot.overallReliability.systemImageName)
                .foregroundStyle(reliabilityColor)
            Text(Self.formatAmount(snapshot.monthToDateTotal))
                .font(.headline)
                .monospacedDigit()
            Text("spent this month")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide overlay")
        }
    }

    private func providerRow(_ provider: Provider) -> some View {
        let status = snapshot.statuses[provider] ?? .staleTransient(lastPolledAt: nil)
        let amount = snapshot.balances[provider] ?? snapshot.perProviderTotals[provider]
        let label = snapshot.balances[provider] != nil ? "left" : "spent"

        return HStack {
            Circle()
                .fill(statusDotColor(status))
                .frame(width: 6, height: 6)
            Text(MenuBarView.providerLabel(provider))
                .font(.caption)
            Spacer()
            if let amount {
                Text(Self.formatAmount(amount))
                    .font(.caption)
                    .monospacedDigit()
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkle")
                    .foregroundStyle(.orange)
                Text("Claude")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Button {
                    Task { await claudePlanSnapshot.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(claudePlanSnapshot.isRefreshing)
                .help("Refresh now — sends one tiny real message to check current usage")
            }
            if let usage = claudePlanSnapshot.usage {
                bar(label: "Session (5h)", percentage: usage.sessionPercentage, resetAt: usage.sessionResetAt)
                bar(label: "Weekly", percentage: usage.weeklyPercentage, resetAt: usage.weeklyResetAt)
            } else {
                Text("Loading…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bar(label: String, percentage: Double, resetAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text("\(Int(percentage))%")
                    .font(.caption)
                    .bold()
                    .monospacedDigit()
            }
            ProgressView(value: min(max(percentage, 0), 100), total: 100)
                .tint(percentage >= 90 ? .red : (percentage >= 75 ? .orange : .green))
            Text("Resets \(resetAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var reliabilityColor: Color {
        switch snapshot.overallReliability {
        case .ok: return .green
        case .syncing: return .orange
        case .needsAttention: return .red
        }
    }

    private func statusDotColor(_ status: ProviderStatus) -> Color {
        if status.needsAttention { return .red }
        if status.isStale { return .orange }
        return .green
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
    }
}
