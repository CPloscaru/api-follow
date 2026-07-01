import Foundation
import Testing
@testable import APIFollow

/// A controllable fake adapter — lets tests dictate exactly what
/// `fetchSpend` returns, and count how many times it was actually called
/// (to verify the overlap guard, D7).
actor FakeAdapterController {
    var callCount = 0
    var result: FetchResult = .success([])
    /// If set, fetchSpend blocks until this continuation is resumed —
    /// used to simulate a slow in-flight request for the overlap test.
    var gate: CheckedContinuation<Void, Never>?

    func recordCall() {
        callCount += 1
    }

    func setResult(_ result: FetchResult) {
        self.result = result
    }

    func waitForGate() async {
        await withCheckedContinuation { continuation in
            self.gate = continuation
        }
    }

    func openGate() {
        gate?.resume()
        gate = nil
    }
}

struct FakeAdapter: ProviderAdapter {
    let provider: Provider
    let controller: FakeAdapterController
    let blocksUntilGateOpen: Bool

    init(provider: Provider, controller: FakeAdapterController, blocksUntilGateOpen: Bool = false) {
        self.provider = provider
        self.controller = controller
        self.blocksUntilGateOpen = blocksUntilGateOpen
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        await controller.recordCall()
        if blocksUntilGateOpen {
            await controller.waitForGate()
        }
        return await controller.result
    }
}

@Suite("Poller")
struct PollerTests {
    static func makePoller(
        adapter: FakeAdapter,
        keychainService: String = "com.apifollow.tests.\(UUID().uuidString)"
    ) throws -> (Poller, KeychainStore, SpendStore) {
        let store = try SpendStore(inMemory: ())
        let keychain = KeychainStore(service: keychainService)
        try keychain.save("fake-admin-key", for: adapter.provider)
        let poller = Poller(store: store, keychain: keychain, adapters: [adapter.provider: adapter])
        return (poller, keychain, store)
    }

    @Test("successful fetch writes records and marks status ok")
    func successfulFetchUpdatesStatus() async throws {
        let controller = FakeAdapterController()
        let record = SpendRecord(
            provider: .anthropic, attributionID: "wrkspc_1", attributionKind: .workspace,
            model: nil, day: Date(), amountUSD: 5.00, polledAt: Date()
        )
        await controller.setResult(.success([record]))
        let adapter = FakeAdapter(provider: .anthropic, controller: controller)
        let (poller, keychain, store) = try Self.makePoller(adapter: adapter)

        await poller.pollNow(.anthropic)

        let status = await poller.status(for: .anthropic)
        guard case .ok = status else {
            Issue.record("expected .ok, got \(status)")
            return
        }

        let latest = try store.latestPerAttribution(for: .anthropic)
        #expect(latest.count == 1)

        try? keychain.delete(for: .anthropic)
    }

    @Test("auth error result marks status staleAuthError")
    func authErrorUpdatesStatus() async throws {
        let controller = FakeAdapterController()
        await controller.setResult(.authError)
        let adapter = FakeAdapter(provider: .openai, controller: controller)
        let (poller, keychain, _) = try Self.makePoller(adapter: adapter)

        await poller.pollNow(.openai)

        let status = await poller.status(for: .openai)
        #expect(status.needsAttention == true)
        guard case .staleAuthError = status else {
            Issue.record("expected .staleAuthError, got \(status)")
            return
        }

        try? keychain.delete(for: .openai)
    }

    @Test("no key configured: pollNow is a no-op, does not call the adapter")
    func noKeyConfiguredSkipsAdapterCall() async throws {
        let controller = FakeAdapterController()
        let adapter = FakeAdapter(provider: .anthropic, controller: controller)
        let store = try SpendStore(inMemory: ())
        let keychain = KeychainStore(service: "com.apifollow.tests.\(UUID().uuidString)")
        // Deliberately do NOT save a key.
        let poller = Poller(store: store, keychain: keychain, adapters: [.anthropic: adapter])

        await poller.pollNow(.anthropic)

        let callCount = await controller.callCount
        #expect(callCount == 0)
    }

    @Test("overlap guard: a poll already in flight is not started again concurrently (D7)")
    func overlapGuardSkipsConcurrentPoll() async throws {
        let controller = FakeAdapterController()
        await controller.setResult(.success([]))
        let adapter = FakeAdapter(provider: .anthropic, controller: controller, blocksUntilGateOpen: true)
        let (poller, keychain, _) = try Self.makePoller(adapter: adapter)

        // Start a poll that will block until we open the gate.
        let firstPoll = Task { await poller.pollNow(.anthropic) }

        // Give the first poll a moment to enter fetchSpend and register
        // as in-flight before the second attempt races it.
        try await Task.sleep(for: .milliseconds(100))

        // Second poll while the first is still in flight — should be
        // skipped entirely (D7), not queued or run concurrently.
        await poller.pollNow(.anthropic)

        let callCountWhileBlocked = await controller.callCount
        #expect(callCountWhileBlocked == 1)

        await controller.openGate()
        await firstPoll.value

        try? keychain.delete(for: .anthropic)
    }

    @Test("repeated transient failures preserve the last known-good poll date")
    func repeatedFailuresPreserveLastGoodDate() async throws {
        let controller = FakeAdapterController()
        let record = SpendRecord(
            provider: .anthropic, attributionID: "wrkspc_1", attributionKind: .workspace,
            model: nil, day: Date(), amountUSD: 1.00, polledAt: Date()
        )
        await controller.setResult(.success([record]))
        let adapter = FakeAdapter(provider: .anthropic, controller: controller)
        let (poller, keychain, _) = try Self.makePoller(adapter: adapter)

        await poller.pollNow(.anthropic)
        guard case .ok(let firstGoodDate) = await poller.status(for: .anthropic) else {
            Issue.record("expected initial success")
            return
        }

        await controller.setResult(.transientFailure(URLError(.timedOut)))
        await poller.pollNow(.anthropic)

        guard case .staleTransient(let preservedDate) = await poller.status(for: .anthropic) else {
            Issue.record("expected .staleTransient after failure")
            return
        }
        #expect(preservedDate == firstGoodDate)

        try? keychain.delete(for: .anthropic)
    }
}
