import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Owns the poll loop for all configured providers. Actor-isolated so the
/// overlap guard (D7) and status map can't race under concurrent access.
actor Poller {
    private let store: SpendStore
    private let keychain: KeychainStore
    private let adapters: [Provider: ProviderAdapter]
    private let pollInterval: TimeInterval

    private var statuses: [Provider: ProviderStatus] = [:]
    /// D7: per-provider in-flight guard. If a poll is still running when
    /// the next timer fires (or a wake-triggered poll overlaps a
    /// scheduled one), the new attempt is skipped rather than firing a
    /// concurrent fetch — prevents duplicate rows / write races.
    private var inFlight: Set<Provider> = []

    private var pollLoopTask: Task<Void, Never>?
    /// D3: held for the poller's whole lifetime so macOS doesn't throttle
    /// the poll loop's Task.sleep when the app has no foreground window.
    /// `NSObjectProtocol` — AppKit-only, so this file is inert (compiles
    /// to a no-op on non-AppKit platforms) if ever built for another OS.
    #if canImport(AppKit)
    private var appNapActivityToken: NSObjectProtocol?
    #endif
    private var wakeObserver: NSObjectProtocol?

    init(
        store: SpendStore,
        keychain: KeychainStore,
        adapters: [Provider: ProviderAdapter],
        pollInterval: TimeInterval = 300
    ) {
        self.store = store
        self.keychain = keychain
        self.adapters = adapters
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() {
        beginAppNapExemption()
        observeWake()

        pollLoopTask?.cancel()
        pollLoopTask = Task {
            while !Task.isCancelled {
                await pollAll()
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    func stop() {
        pollLoopTask?.cancel()
        pollLoopTask = nil
        if let wakeObserver {
            #if canImport(AppKit)
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            #endif
        }
        wakeObserver = nil
        endAppNapExemption()
    }

    private func beginAppNapExemption() {
        #if canImport(AppKit)
        guard appNapActivityToken == nil else { return }
        appNapActivityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated],
            reason: "Poll configured LLM provider APIs for spend data on a fixed schedule"
        )
        #endif
    }

    private func endAppNapExemption() {
        #if canImport(AppKit)
        if let token = appNapActivityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        appNapActivityToken = nil
        #endif
    }

    /// D15: lid-closed sleep is NOT covered by the App Nap exemption above
    /// — without this, every wake produces a stale/attention badge purely
    /// from elapsed wall-clock time, training the user to ignore real
    /// problems (alarm fatigue). Force an immediate poll on wake instead
    /// of waiting for the next scheduled tick.
    private func observeWake() {
        #if canImport(AppKit)
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.pollAll() }
        }
        #endif
    }

    // MARK: - Polling

    func pollAll() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in adapters.keys {
                group.addTask { await self.pollNow(provider) }
            }
        }
    }

    /// D7 overlap guard lives here: a provider already `inFlight` skips
    /// this cycle entirely rather than racing a second fetch.
    func pollNow(_ provider: Provider) async {
        guard let adapter = adapters[provider] else { return }
        guard !inFlight.contains(provider) else { return }
        inFlight.insert(provider)
        defer { inFlight.remove(provider) }

        let key: String?
        do {
            key = try keychain.read(for: provider)
        } catch {
            key = nil
        }

        guard let key, !key.isEmpty else {
            // No key configured yet — not an error state, just nothing to do.
            return
        }

        let until = Date()
        let calendar = Calendar(identifier: .gregorian)
        guard let since = calendar.date(byAdding: .day, value: -31, to: until) else { return }

        let result = await adapter.fetchSpend(adminKey: key, since: since, until: until)
        apply(result, for: provider)
    }

    private func apply(_ result: FetchResult, for provider: Provider) {
        let lastGood = lastKnownGoodPollDate(for: provider)

        switch result {
        case .success(let records):
            do {
                try store.write(records)
                statuses[provider] = .ok(lastPolledAt: Date())
            } catch {
                // A write failure is a local problem, not an API problem —
                // still surfaces as parseError-family since it means the
                // number we have is not trustworthy to display as current.
                statuses[provider] = .staleParseError(lastPolledAt: lastGood)
            }
        case .transientFailure:
            statuses[provider] = .staleTransient(lastPolledAt: lastGood)
        case .rateLimited:
            statuses[provider] = .staleRateLimited(lastPolledAt: lastGood)
        case .authError:
            statuses[provider] = .staleAuthError(lastPolledAt: lastGood)
        case .parseError:
            statuses[provider] = .staleParseError(lastPolledAt: lastGood)
        }
    }

    private func lastKnownGoodPollDate(for provider: Provider) -> Date? {
        if case .ok(let date) = statuses[provider] { return date }
        // Preserve the prior last-known-good date across repeated
        // failures — e.g. transient -> transient shouldn't lose track of
        // when we last actually succeeded.
        switch statuses[provider] {
        case .staleTransient(let date), .staleRateLimited(let date),
             .staleAuthError(let date), .staleParseError(let date):
            return date
        default:
            return nil
        }
    }

    // MARK: - Read

    func status(for provider: Provider) -> ProviderStatus {
        statuses[provider] ?? .staleTransient(lastPolledAt: nil)
    }

    func allStatuses() -> [Provider: ProviderStatus] {
        statuses
    }
}
