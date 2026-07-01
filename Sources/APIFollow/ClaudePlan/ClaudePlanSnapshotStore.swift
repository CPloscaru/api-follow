import Foundation
import Combine

/// MainActor-isolated read cache over `ClaudePlanUsagePoller`, same
/// pattern as `SpendSnapshotStore`/D9 — SwiftUI reads this, not the
/// actor directly.
@MainActor
final class ClaudePlanSnapshotStore: ObservableObject {
    @Published private(set) var usage: ClaudePlanUsage?
    @Published private(set) var isAvailable = false

    private let poller: ClaudePlanUsagePoller

    init(poller: ClaudePlanUsagePoller) {
        self.poller = poller
    }

    func refresh() async {
        usage = await poller.latestUsage
        isAvailable = await poller.isAvailable
    }
}
