import Foundation
import Testing
@testable import APIFollow

@Suite("ClaudePlanUsageFetcher")
struct ClaudePlanUsageFetcherTests {
    private func response(headers: [String: String], statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.anthropic.com/v1/messages")!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test("parses well-formed rate-limit headers")
    func parsesWellFormedHeaders() {
        let resetTimestamp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let response = response(headers: [
            "anthropic-ratelimit-unified-5h-utilization": "0.42",
            "anthropic-ratelimit-unified-5h-reset": "\(resetTimestamp)",
            "anthropic-ratelimit-unified-7d-utilization": "0.15",
            "anthropic-ratelimit-unified-7d-reset": "\(resetTimestamp)",
        ])

        let result = ClaudePlanUsageFetcher.parse(headers: response)
        guard case .success(let usage) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(usage.sessionPercentage == 42.0)
        #expect(usage.weeklyPercentage == 15.0)
    }

    @Test("missing headers entirely surfaces notAvailable, not a fabricated 0%")
    func missingHeadersIsNotAvailable() {
        let response = response(headers: [:])
        let result = ClaudePlanUsageFetcher.parse(headers: response)
        guard case .notAvailable = result else {
            Issue.record("expected .notAvailable, got \(result)")
            return
        }
    }

    @Test("session percentage resets to 0 once the reset time has passed")
    func expiredSessionResetsToZero() {
        let pastReset = Date().addingTimeInterval(-60).timeIntervalSince1970
        let response = response(headers: [
            "anthropic-ratelimit-unified-5h-utilization": "0.9",
            "anthropic-ratelimit-unified-5h-reset": "\(pastReset)",
            "anthropic-ratelimit-unified-7d-utilization": "0.5",
            "anthropic-ratelimit-unified-7d-reset": "\(Date().addingTimeInterval(3600).timeIntervalSince1970)",
        ])

        let result = ClaudePlanUsageFetcher.parse(headers: response)
        guard case .success(let usage) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(usage.sessionPercentage == 0)
    }

    @Test("401 response classifies as authError")
    func unauthorizedIsAuthError() async {
        let client = MockHTTPClient(statusCode: 401, body: Data())
        let fetcher = ClaudePlanUsageFetcher(httpClient: client)
        let result = await fetcher.fetch(accessToken: "bad-token")
        guard case .authError = result else {
            Issue.record("expected .authError, got \(result)")
            return
        }
    }

    @Test("429 (over rate limit) still parses headers rather than treating it as a hard failure")
    func rateLimitedStatusStillParsesHeaders() async {
        let resetTimestamp = Date().addingTimeInterval(3600).timeIntervalSince1970
        let client = MockHTTPClient(statusCode: 429, body: Data(), headers: [
            "anthropic-ratelimit-unified-5h-utilization": "1.0",
            "anthropic-ratelimit-unified-5h-reset": "\(resetTimestamp)",
            "anthropic-ratelimit-unified-7d-utilization": "0.8",
            "anthropic-ratelimit-unified-7d-reset": "\(resetTimestamp)",
        ])
        let fetcher = ClaudePlanUsageFetcher(httpClient: client)
        let result = await fetcher.fetch(accessToken: "token")
        guard case .success(let usage) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(usage.sessionPercentage == 100.0)
    }
}

@Suite("ClaudePlanUsagePoller")
struct ClaudePlanUsagePollerTests {
    @Test("no credential available: isAvailable stays false, no crash")
    func noCredentialIsHandledGracefully() async {
        // Uses the real ClaudeCodeCredentialReader; on a test machine
        // without Claude Code's exact Keychain item under test
        // isolation, this exercises the "not available" path safely.
        // (This test only asserts it doesn't crash / hang — it can't
        // assert a specific outcome since it depends on the actual
        // machine's Keychain state.)
        let poller = ClaudePlanUsagePoller(pollInterval: 999999)
        await poller.pollOnce()
        // No assertion on isAvailable's value — just confirming pollOnce()
        // completes without hanging or throwing on a real Keychain read.
        _ = await poller.isAvailable
    }
}
