import Foundation
import Combine

/// MainActor-isolated read cache over `ClaudePlanUsagePoller`, same
/// pattern as `SpendSnapshotStore`/D9 — SwiftUI reads this, not the
/// actor directly.
@MainActor
final class ClaudePlanSnapshotStore: ObservableObject {
    @Published private(set) var usage: ClaudePlanUsage?
    @Published private(set) var isAvailable = false
    @Published private(set) var isRefreshing = false

    private let poller: ClaudePlanUsagePoller

    init(poller: ClaudePlanUsagePoller) {
        self.poller = poller
    }

    func refresh() async {
        usage = await poller.latestUsage
        isAvailable = await poller.isAvailable
    }

    /// Manual "refresh now" — burns a tiny real message against the
    /// user's quota immediately, rather than waiting up to 20 minutes
    /// for the next scheduled poll (see ClaudePlanUsagePoller's doc
    /// comment for why the interval is that long by default).
    func refreshNow() async {
        isRefreshing = true
        await poller.pollOnce()
        await refresh()
        isRefreshing = false
    }
}
