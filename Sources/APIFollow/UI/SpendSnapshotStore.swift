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
    @Published private(set) var statuses: [Provider: ProviderStatus] = [:]
    @Published private(set) var lastRefreshedAt: Date?

    private let store: SpendStore
    private let poller: Poller
    private let providers: [Provider]

    init(store: SpendStore, poller: Poller, providers: [Provider]) {
        self.store = store
        self.poller = poller
        self.providers = providers
    }

    /// D11: menu bar headline = month-to-date total, summed from each
    /// attribution's last-known value regardless of freshness (D12) — a
    /// provider in an error state still contributes its last known
    /// number; the reliability glyph (see `overallReliability`) is a
    /// separate signal from the number itself.
    func refresh() async {
        let statuses = await poller.allStatuses()
        let total = (try? store.monthToDateTotal(providers: providers, now: Date())) ?? monthToDateTotal

        self.statuses = statuses
        self.monthToDateTotal = total
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
