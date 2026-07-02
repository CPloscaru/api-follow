import SwiftUI
import ServiceManagement

@main
struct APIFollowApp: App {
    private let store: SpendStore
    private let keychain = KeychainStore()
    private let poller: Poller
    private let snapshot: SpendSnapshotStore
    private let claudePlanPoller = ClaudePlanUsagePoller()
    private let claudePlanSnapshot: ClaudePlanSnapshotStore
    private let floatingWidget: FloatingWidgetController

    private static let providers: [Provider] = [.anthropic, .openai, .openrouter, .fal]

    init() {
        let store: SpendStore
        do {
            store = try SpendStore(path: Self.databasePath())
        } catch {
            // Falling back to in-memory keeps the app usable (you can
            // still see live data this session) rather than crashing on
            // launch over a local storage problem — but nothing persists
            // across restarts until the underlying issue is fixed.
            store = (try? SpendStore(inMemory: ())) ?? { fatalError("failed to create even an in-memory SpendStore: \(error)") }()
        }
        self.store = store

        let keychain = KeychainStore()
        let adapters: [Provider: ProviderAdapter] = [
            .anthropic: AnthropicAdapter(),
            .openai: OpenAIAdapter(),
            .openrouter: OpenRouterAdapter(),
            .fal: FalAdapter(),
        ]
        let balanceFetchers: [Provider: BalanceFetcher] = [
            .openrouter: OpenRouterBalanceFetcher(),
            .fal: FalBalanceFetcher(),
        ]
        let poller = Poller(store: store, keychain: keychain, adapters: adapters, balanceFetchers: balanceFetchers)
        self.poller = poller
        self.snapshot = SpendSnapshotStore(store: store, poller: poller, keychain: keychain, providers: Self.providers)

        let claudePlanPoller = self.claudePlanPoller
        let claudePlanSnapshot = ClaudePlanSnapshotStore(poller: claudePlanPoller)
        self.claudePlanSnapshot = claudePlanSnapshot
        self.floatingWidget = FloatingWidgetController(snapshot: snapshot, claudePlanSnapshot: claudePlanSnapshot)

        Self.registerLaunchAtLogin()

        Task {
            await poller.start()
        }
        Task { @MainActor [snapshot] in
            // Cheap local-state refresh loop — reads from the poller's
            // already-updated status map and the DB Poller just wrote to;
            // does not itself call any provider API. Runs more often than
            // the 5-min poll interval so the UI reflects a poll (or a
            // manual refresh, or a wake-triggered poll) promptly.
            while true {
                await snapshot.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        Task {
            // Push-based, not poll-based: the moment pollOnce() (either
            // the automatic 20-min cycle or a manual "refresh now")
            // finishes, it calls this directly — the UI updates as soon
            // as the real answer arrives, not on some unrelated timer
            // that might still be mid-wait when the response lands.
            await claudePlanPoller.setOnUpdate { @MainActor [claudePlanSnapshot] in
                await claudePlanSnapshot.refresh()
            }
            await claudePlanPoller.start()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(snapshot: snapshot, claudePlanSnapshot: claudePlanSnapshot, floatingWidget: floatingWidget)
        } label: {
            MenuBarLabelView(snapshot: snapshot, claudePlanSnapshot: claudePlanSnapshot)
        }
        .menuBarExtraStyle(.window)

        Window("API Follow Dashboard", id: "dashboard") {
            DashboardView(store: store, providers: Self.providers, snapshot: snapshot)
        }
        .defaultSize(width: 480, height: 420)
    }

    private static func databasePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent("APIFollow", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("spend.sqlite").path
    }

    /// D14: an "ambient" menu bar tool that requires manually relaunching
    /// after every reboot isn't ambient — register with SMAppService so
    /// it starts automatically at login. Best-effort: a failure here
    /// (e.g. missing entitlement in a dev/unsigned build) shouldn't
    /// prevent the app from running this session.
    private static func registerLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Non-fatal — see doc comment above.
        }
    }
}
