import SwiftUI

/// D4: `.window` style content, not `.menu` — avoids the known SwiftUI
/// bug (FB13683950/FB13683957) where `.menu` style doesn't reliably
/// re-render on open. Full custom-view control here also matches D9's
/// in-memory snapshot read pattern (no disk hit on render).
struct MenuBarView: View {
    @ObservedObject var snapshot: SpendSnapshotStore
    @ObservedObject var claudePlanSnapshot: ClaudePlanSnapshotStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headline

            Divider()

            ForEach(snapshot.providers, id: \.self) { provider in
                ProviderRow(provider: provider, snapshot: snapshot)
            }

            if let error = snapshot.saveKeyError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if claudePlanSnapshot.isAvailable {
                Divider()
                claudePlanSection
            }

            Divider()

            HStack {
                if let lastRefreshedAt = snapshot.lastRefreshedAt {
                    Text("As of \(lastRefreshedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Dashboard") { openWindow(id: "dashboard") }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    /// Only shown when Claude Code's OAuth token was found on this
    /// machine (opportunistic — most users won't have it). Session (5h)
    /// and weekly (7d) only — no per-model breakdown, see
    /// ClaudePlanUsage's doc comment for why.
    private var claudePlanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Plan")
                .font(.subheadline)
                .bold()
            if let usage = claudePlanSnapshot.usage {
                planBar(label: "Session (5h)", percentage: usage.sessionPercentage, resetAt: usage.sessionResetAt)
                planBar(label: "Weekly", percentage: usage.weeklyPercentage, resetAt: usage.weeklyResetAt)
            } else {
                Text("Checking…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func planBar(label: String, percentage: Double, resetAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text("\(Int(percentage))%")
                    .font(.caption)
                    .monospacedDigit()
            }
            ProgressView(value: min(max(percentage, 0), 100), total: 100)
                .tint(percentage >= 90 ? .red : (percentage >= 75 ? .orange : .green))
            Text("Resets \(resetAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

    private var formattedTotal: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter.string(from: snapshot.monthToDateTotal as NSDecimalNumber) ?? "$0.00"
    }

    static func providerLabel(_ provider: Provider) -> String {
        switch provider {
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        }
    }

    /// D6: four distinct "not current" states get distinct labels, not a
    /// single generic "stale" string — auth-error and parse-error need
    /// to visually read as "needs your attention", not "syncing".
    static func statusLabel(_ status: ProviderStatus) -> String {
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

    static func statusColor(_ status: ProviderStatus) -> Color {
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

/// Shows either the compact status row (with a "Change key" affordance)
/// or the key-entry field, per provider. This is the only user-input
/// surface in v1 (design doc Test Plan). Deliberately inline in the
/// popover rather than a separate settings window — keeps the "menu bar
/// as the star" surface self-contained for v1's 3 providers.
///
/// A provider with a configured key that's still rejected (auth error)
/// MUST be editable, not just providers with no key yet — this was a
/// real gap: the first version only showed the entry field when no key
/// existed at all, leaving no way to correct a wrong/invalid key once
/// saved.
private struct ProviderRow: View {
    let provider: Provider
    @ObservedObject var snapshot: SpendSnapshotStore
    @State private var isEditing = false
    @State private var keyText: String = ""
    @State private var isSaving = false

    private var hasKey: Bool { snapshot.keysConfigured.contains(provider) }
    private var status: ProviderStatus { snapshot.statuses[provider] ?? .staleTransient(lastPolledAt: nil) }

    var body: some View {
        if hasKey && !isEditing {
            HStack {
                Text(MenuBarView.providerLabel(provider))
                Spacer()
                Text(MenuBarView.statusLabel(status))
                    .font(.caption)
                    .foregroundStyle(MenuBarView.statusColor(status))
                Button("Change key") { isEditing = true }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(MenuBarView.providerLabel(provider))
                        .font(.subheadline)
                        .bold()
                    if hasKey {
                        Spacer()
                        Button("Cancel") { isEditing = false; keyText = "" }
                            .buttonStyle(.plain)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(hintText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    SecureField("Admin / Management key", text: $keyText)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        isSaving = true
                        Task {
                            await snapshot.saveKey(trimmed, for: provider)
                            keyText = ""
                            isSaving = false
                            isEditing = false
                        }
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var hintText: String {
        switch provider {
        case .anthropic:
            return "Admin API key (sk-ant-admin01-…), not your regular API key. Console → Settings → Organization."
        case .openai:
            return "Admin key, not your regular API key. platform.openai.com/settings/organization/admin-keys"
        case .openrouter:
            return "Management (Provisioning) key, not your regular API key. openrouter.ai/settings/management-keys"
        }
    }
}
