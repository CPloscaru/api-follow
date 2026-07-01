import Foundation
import os.log

private let claudePlanLog = Logger(subsystem: "com.apifollow.app", category: "ClaudePlan")

/// Polls Claude.ai plan usage far less often than the 5-minute
/// SpendRecord loop — each poll burns a tiny real message (see
/// ClaudePlanUsageFetcher's doc comment) so this defaults to 20
/// minutes, not 5.
actor ClaudePlanUsagePoller {
    private let credentialReader: ClaudeCodeCredentialReader
    private let fetcher: ClaudePlanUsageFetcher
    private let pollInterval: TimeInterval

    private(set) var latestUsage: ClaudePlanUsage?
    private(set) var isAvailable = false
    private var pollLoopTask: Task<Void, Never>?

    /// Invoked right after every poll (automatic or manual) sets
    /// `latestUsage`/`isAvailable` — pushes the update to the UI the
    /// moment a response actually arrives, instead of the UI having to
    /// poll this actor on its own timer and potentially wait up to a
    /// full refresh cycle after the real work already finished.
    private var onUpdate: (@Sendable () async -> Void)?

    init(
        credentialReader: ClaudeCodeCredentialReader = ClaudeCodeCredentialReader(),
        fetcher: ClaudePlanUsageFetcher = ClaudePlanUsageFetcher(),
        pollInterval: TimeInterval = 1200
    ) {
        self.credentialReader = credentialReader
        self.fetcher = fetcher
        self.pollInterval = pollInterval
    }

    func setOnUpdate(_ handler: @escaping @Sendable () async -> Void) {
        onUpdate = handler
    }

    func start() {
        pollLoopTask?.cancel()
        pollLoopTask = Task {
            while !Task.isCancelled {
                await pollOnce()
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    func stop() {
        pollLoopTask?.cancel()
        pollLoopTask = nil
    }

    func pollOnce() async {
        claudePlanLog.info("polling for Claude Code credential")
        guard let token = credentialReader.readAccessToken() else {
            claudePlanLog.notice("no Claude Code credential found (not installed/logged in, or read timed out)")
            isAvailable = false
            latestUsage = nil
            await onUpdate?()
            return
        }
        claudePlanLog.info("credential found, fetching plan usage")

        let result = await fetcher.fetch(accessToken: token)
        switch result {
        case .success(let usage):
            claudePlanLog.info("plan usage fetched: session \(Int(usage.sessionPercentage))%, weekly \(Int(usage.weeklyPercentage))%")
            isAvailable = true
            latestUsage = usage
        case .notAvailable:
            claudePlanLog.notice("rate-limit headers not present on response — treating as unavailable")
            isAvailable = false
            latestUsage = nil
        case .authError:
            claudePlanLog.error("auth error fetching plan usage (token invalid/expired)")
            isAvailable = latestUsage != nil
        case .transientFailure(let error):
            claudePlanLog.error("transient failure fetching plan usage: \(String(describing: error), privacy: .public)")
            // Keep showing the last known-good reading rather than
            // blanking it on a transient hiccup — same "don't lose the
            // last good number over a temporary failure" reasoning as
            // the main Poller's status handling.
            isAvailable = latestUsage != nil
        }

        // Push the update immediately — see `onUpdate`'s doc comment.
        await onUpdate?()
    }
}
