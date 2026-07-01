import Foundation
import Combine

/// D9: the menu bar reads this in-memory snapshot directly rather than
/// hitting SQLite on every SwiftUI re-render. SpendStore remains the
/// durable source of truth; this is a MainActor-isolated read cache that
/// `refresh()` re-hydrates from it after each poll cycle.
///
/// Uses `ObservableObject`/`@Published` (Combine) rather than the newer
/// `@Observable` macro — `@Observable` requires macOS 14+, and the design
/// doc's stated floor is macOS 13 (Ventura), set specifically to support
/// `MenuBarExtra`. Silently bumping the real minimum OS to 14 to use a
/// nicer observation API would be exactly the kind of unstated constraint
/// change the eng review process exists to catch.
@MainActor
final class SpendSnapshotStore: ObservableObject {
    @Published private(set) var monthToDateTotal: Decimal = 0
    /// Per-provider month-to-date spend — backs the popover's provider
    /// rows so each shows its own number ("OpenRouter $1.20"), not just
    /// a generic "OK" status word.
    @Published private(set) var perProviderTotals: [Provider: Decimal] = [:]
    @Published private(set) var statuses: [Provider: ProviderStatus] = [:]
    @Published private(set) var lastRefreshedAt: Date?
    /// Remaining credit balance per provider — only populated for
    /// providers with a prepaid-credit model (OpenRouter, fal.ai). See
    /// BalanceFetcher's doc comment for why Anthropic/OpenAI aren't here.
    @Published private(set) var balances: [Provider: Decimal] = [:]
    /// Providers that currently have a key saved in the Keychain — drives
    /// whether the menu bar shows a status row or a key-entry field for
    /// each provider.
    @Published private(set) var keysConfigured: Set<Provider> = []
    /// Set (and auto-cleared) when `saveKey` fails, so the UI can surface
    /// a visible error instead of the save silently doing nothing.
    @Published var saveKeyError: String?

    private let store: SpendStore
    private let poller: Poller
    private let keychain: KeychainStore
    let providers: [Provider]

    init(store: SpendStore, poller: Poller, keychain: KeychainStore, providers: [Provider]) {
        self.store = store
        self.poller = poller
        self.keychain = keychain
        self.providers = providers
    }

    /// Writes the key to Keychain, updates `keysConfigured` immediately
    /// (so the UI swaps from the entry field to the status row without
    /// waiting for the next 30s refresh tick), and kicks an immediate
    /// poll for that provider so the user sees a number right away
    /// rather than waiting up to 5 minutes.
    func saveKey(_ key: String, for provider: Provider) async {
        do {
            try keychain.save(key, for: provider)
            keysConfigured.insert(provider)
            saveKeyError = nil
        } catch {
            saveKeyError = "Couldn't save key for \(provider.rawValue): \(error.localizedDescription)"
            return
        }
        await poller.pollNow(provider)
        await refresh()
    }

    /// D11: menu bar headline = month-to-date total, summed from each
    /// attribution's last-known value regardless of freshness (D12) — a
    /// provider in an error state still contributes its last known
    /// number; the reliability glyph (see `overallReliability`) is a
    /// separate signal from the number itself.
    func refresh() async {
        let statuses = await poller.allStatuses()
        let balances = await poller.allBalances()
        let perProviderTotals = (try? store.monthToDateTotals(providers: providers, now: Date())) ?? self.perProviderTotals
        let total = perProviderTotals.values.reduce(0, +)
        var configured: Set<Provider> = []
        for provider in providers {
            if let key = try? keychain.read(for: provider), !key.isEmpty {
                configured.insert(provider)
            }
        }

        self.statuses = statuses
        self.balances = balances
        self.perProviderTotals = perProviderTotals
        self.monthToDateTotal = total
        self.keysConfigured = configured
        self.lastRefreshedAt = Date()
    }

    /// D12's aggregation rule for the ONE glyph shown next to the
    /// headline number: "needs attention" (auth/parse error on any
    /// provider) beats "syncing" (transient/rate-limited on any
    /// provider) beats "ok" (every configured provider is current).
    var overallReliability: ReliabilityGlyph {
        let values = providers.map { statuses[$0] ?? .staleTransient(lastPolledAt: nil) }
        if values.contains(where: { $0.needsAttention }) {
            return .needsAttention
        }
        if values.contains(where: { $0.isStale }) {
            return .syncing
        }
        return .ok
    }

    enum ReliabilityGlyph {
        case ok
        case syncing
        case needsAttention

        var systemImageName: String {
            switch self {
            case .ok: return "checkmark.circle.fill"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .needsAttention: return "exclamationmark.triangle.fill"
            }
        }
    }
}
