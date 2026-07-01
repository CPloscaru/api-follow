import Foundation

/// Fetches Claude.ai plan usage (session/weekly %) via Claude Code's own
/// OAuth token.
///
/// **Why this is expensive and polled sparingly:** Anthropic's dedicated
/// OAuth usage endpoint is disabled (confirmed by community tooling that
/// already tried it), so the only way to read rate-limit state via an
/// OAuth token is to make a real, minimal `/v1/messages` call (1 output
/// token, cheapest model) and read the `anthropic-ratelimit-unified-*`
/// headers off the response — every poll costs a tiny sliver of the
/// user's real quota. `ClaudePlanUsagePoller` deliberately polls this
/// far less often than the 5-minute SpendRecord loop.
struct ClaudePlanUsageFetcher {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetch(accessToken: String) async -> ClaudePlanFetchResult {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(-1))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 1,
            "messages": [["role": "user", "content": "hi"]],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(-1))
        }
        request.httpBody = bodyData

        let response: URLResponse
        do {
            (_, response) = try await httpClient.data(for: request)
        } catch {
            return .transientFailure(error)
        }

        guard let http = response as? HTTPURLResponse else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(-1))
        }

        if http.statusCode == 401 || http.statusCode == 403 {
            return .authError
        }
        // Rate-limit headers are present on both success AND 429
        // (over-limit) responses — parse from headers regardless of
        // status code, don't gate on 200 only.
        guard http.statusCode == 200 || http.statusCode == 429 else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(http.statusCode))
        }

        return Self.parse(headers: http)
    }

    static func parse(headers response: HTTPURLResponse) -> ClaudePlanFetchResult {
        func headerDouble(_ name: String) -> Double? {
            response.value(forHTTPHeaderField: name).flatMap(Double.init)
        }

        guard let sessionUtilization = headerDouble("anthropic-ratelimit-unified-5h-utilization"),
              let weeklyUtilization = headerDouble("anthropic-ratelimit-unified-7d-utilization")
        else {
            // Headers missing entirely — this account/token doesn't
            // expose unified rate-limit data (D8 philosophy: don't
            // guess, surface it as unavailable rather than showing 0%
            // as if it were a real reading).
            return .notAvailable
        }

        let sessionResetTimestamp = headerDouble("anthropic-ratelimit-unified-5h-reset") ?? 0
        let weeklyResetTimestamp = headerDouble("anthropic-ratelimit-unified-7d-reset") ?? 0

        let now = Date()
        var sessionPercentage = sessionUtilization * 100.0
        let sessionResetAt = sessionResetTimestamp > 0
            ? Date(timeIntervalSince1970: sessionResetTimestamp)
            : now.addingTimeInterval(5 * 3600)
        // If the 5h window already elapsed, the session has reset even
        // if this particular response is momentarily stale about it.
        if sessionResetAt < now {
            sessionPercentage = 0
        }

        let weeklyPercentage = weeklyUtilization * 100.0
        let weeklyResetAt = weeklyResetTimestamp > 0
            ? Date(timeIntervalSince1970: weeklyResetTimestamp)
            : now.addingTimeInterval(7 * 24 * 3600)

        return .success(
            ClaudePlanUsage(
                sessionPercentage: sessionPercentage,
                sessionResetAt: sessionResetAt,
                weeklyPercentage: weeklyPercentage,
                weeklyResetAt: weeklyResetAt,
                fetchedAt: now
            )
        )
    }
}
