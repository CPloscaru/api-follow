import SwiftUI

/// D4: `.window` style content, not `.menu` — avoids the known SwiftUI
/// bug (FB13683950/FB13683957) where `.menu` style doesn't reliably
/// re-render on open. Full custom-view control here also matches D9's
/// in-memory snapshot read pattern (no disk hit on render).
struct MenuBarView: View {
    @ObservedObject var snapshot: SpendSnapshotStore
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
            return "Your regular OpenRouter API key (sk-or-v1-…) — no Management key needed. openrouter.ai/keys"
        }
    }
}
