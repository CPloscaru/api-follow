import Foundation
import os.log
#if canImport(AppKit)
import AppKit
#endif

private let pollerLog = Logger(subsystem: "com.apifollow.app", category: "Poller")

/// Owns the poll loop for all configured providers. Actor-isolated so the
/// overlap guard (D7) and status map can't race under concurrent access.
actor Poller {
    private let store: SpendStore
    private let keychain: KeychainStore
    private let adapters: [Provider: ProviderAdapter]
    private let balanceFetchers: [Provider: BalanceFetcher]
    private let pollInterval: TimeInterval

    private var statuses: [Provider: ProviderStatus] = [:]
    /// Remaining credit balance, only for providers with a
    /// `BalanceFetcher` (OpenRouter, fal.ai — see BalanceFetcher's doc
    /// comment for why Anthropic/OpenAI don't have this). Best-effort:
    /// a balance fetch failing doesn't affect `statuses`/spend polling
    /// at all, it's a separate, lower-stakes concern.
    private var balances: [Provider: Decimal] = [:]
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
        balanceFetchers: [Provider: BalanceFetcher] = [:],
        pollInterval: TimeInterval = 300
    ) {
        self.store = store
        self.keychain = keychain
        self.adapters = adapters
        self.balanceFetchers = balanceFetchers
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
            pollerLog.error("\(provider.rawValue, privacy: .public): Keychain read threw: \(String(describing: error), privacy: .public)")
            key = nil
        }

        guard let key, !key.isEmpty else {
            // No key configured yet — not an error state, just nothing to do.
            pollerLog.notice("\(provider.rawValue, privacy: .public): pollNow called but no key configured, skipping")
            return
        }

        pollerLog.info("\(provider.rawValue, privacy: .public): starting poll")

        let until = Date()
        let calendar = Calendar(identifier: .gregorian)
        guard let since = calendar.date(byAdding: .day, value: -31, to: until) else { return }

        let result = await adapter.fetchSpend(adminKey: key, since: since, until: until)
        apply(result, for: provider)

        if let balanceFetcher = balanceFetchers[provider] {
            let balanceResult = await balanceFetcher.fetchBalance(adminKey: key)
            switch balanceResult {
            case .success(let amount):
                balances[provider] = amount
                pollerLog.info("\(provider.rawValue, privacy: .public): balance fetched: \(String(describing: amount), privacy: .public)")
            case .authError, .transientFailure, .parseError:
                // Best-effort — leave the last known balance in place
                // rather than blanking it over a hiccup, same reasoning
                // as spend status handling.
                pollerLog.notice("\(provider.rawValue, privacy: .public): balance fetch failed, keeping last known value")
            }
        }
    }

    private func apply(_ result: FetchResult, for provider: Provider) {
        let lastGood = lastKnownGoodPollDate(for: provider)

        switch result {
        case .success(let records):
            do {
                try store.write(records)
                statuses[provider] = .ok(lastPolledAt: Date())
                pollerLog.info("\(provider.rawValue, privacy: .public): poll succeeded, \(records.count) record(s)")
            } catch {
                // A write failure is a local problem, not an API problem —
                // still surfaces as parseError-family since it means the
                // number we have is not trustworthy to display as current.
                statuses[provider] = .staleParseError(lastPolledAt: lastGood)
                pollerLog.error("\(provider.rawValue, privacy: .public): SQLite write failed: \(String(describing: error), privacy: .public)")
            }
        case .transientFailure(let error):
            statuses[provider] = .staleTransient(lastPolledAt: lastGood)
            pollerLog.error("\(provider.rawValue, privacy: .public): transient failure: \(String(describing: error), privacy: .public)")
        case .rateLimited:
            statuses[provider] = .staleRateLimited(lastPolledAt: lastGood)
            pollerLog.notice("\(provider.rawValue, privacy: .public): rate limited")
        case .authError:
            statuses[provider] = .staleAuthError(lastPolledAt: lastGood)
            pollerLog.error("\(provider.rawValue, privacy: .public): auth error (401/403) — key likely invalid or wrong key type")
        case .parseError(let error):
            statuses[provider] = .staleParseError(lastPolledAt: lastGood)
            pollerLog.error("\(provider.rawValue, privacy: .public): parse error: \(String(describing: error), privacy: .public)")
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

    func allBalances() -> [Provider: Decimal] {
        balances
    }
}
