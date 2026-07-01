import Foundation

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

    init(
        credentialReader: ClaudeCodeCredentialReader = ClaudeCodeCredentialReader(),
        fetcher: ClaudePlanUsageFetcher = ClaudePlanUsageFetcher(),
        pollInterval: TimeInterval = 1200
    ) {
        self.credentialReader = credentialReader
        self.fetcher = fetcher
        self.pollInterval = pollInterval
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
        guard let token = credentialReader.readAccessToken() else {
            isAvailable = false
            latestUsage = nil
            return
        }

        let result = await fetcher.fetch(accessToken: token)
        switch result {
        case .success(let usage):
            isAvailable = true
            latestUsage = usage
        case .notAvailable:
            isAvailable = false
            latestUsage = nil
        case .authError, .transientFailure:
            // Keep showing the last known-good reading rather than
            // blanking it on a transient hiccup — same "don't lose the
            // last good number over a temporary failure" reasoning as
            // the main Poller's status handling.
            isAvailable = latestUsage != nil
        }
    }
}
