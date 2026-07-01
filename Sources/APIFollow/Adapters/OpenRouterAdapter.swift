import Foundation

/// Calls OpenRouter's self-key introspection endpoint (`GET /api/v1/key`).
///
/// **Revised (2026-07-01): this does NOT use a Management/Provisioning
/// key.** The original design assumed `/api/v1/activity` (Management key
/// required) — but Management keys aren't available on every OpenRouter
/// account (confirmed by the user directly: not available on theirs).
/// `/api/v1/key` works with a REGULAR OpenRouter API key and returns
/// that key's own `usage_monthly` — a self-introspection endpoint ("tell
/// me about myself"), not an org-admin one. This is actually a better
/// fit than the Activity endpoint: it gives real per-key attribution for
/// free (you're authenticated AS the key being reported on) and returns
/// month-to-date directly, matching D11's headline number exactly.
///
/// Tradeoff: no per-day or per-model breakdown — `usage_monthly` is a
/// single running total, not a day-bucketed history. Stored under a
/// fixed "start of current month" day key (not "today") so repeated
/// polls within the same month correctly overwrite rather than sum
/// (summing a cumulative total across multiple days would massively
/// overcount, the same class of bug the monthToDateTotal query already
/// guards against for day-bucketed providers). OpenRouter's dashboard
/// breakdown (T7) will show a monthly figure only, not by-day/by-model,
/// unless a future account upgrade grants Management key access.
struct OpenRouterAdapter: ProviderAdapter {
    let provider: Provider = .openrouter
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        let url = URL(string: "https://openrouter.ai/api/v1/key")!

        var request = URLRequest(url: url)
        request.setValue("Bearer \(adminKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await httpClient.data(for: request)
        } catch {
            return .transientFailure(error)
        }

        guard let http = response as? HTTPURLResponse else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(-1))
        }

        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        if let classified = HTTPClassifier.classify(statusCode: http.statusCode, retryAfterHeader: retryAfter) {
            return classified
        }

        return Self.parse(data, now: until)
    }

    /// Strict parsing (D8) — see AnthropicAdapter.parse for rationale.
    /// `now` is injected (rather than reading `Date()` internally) so
    /// tests can control which month the record lands in.
    static func parse(_ data: Data, now: Date) -> FetchResult {
        struct Response: Decodable {
            struct KeyData: Decodable {
                let usageMonthly: Double
                let label: String?
                enum CodingKeys: String, CodingKey {
                    case usageMonthly = "usage_monthly"
                    case label
                }
            }
            let data: KeyData
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return .parseError(error)
        }

        guard decoded.data.usageMonthly.isFinite, decoded.data.usageMonthly >= 0 else {
            return .parseError(ProviderAdapterError.invalidAmount("non-finite or negative usage_monthly: \(decoded.data.usageMonthly)"))
        }

        // Precision guard, same rationale as OpenAIAdapter/original
        // OpenRouterAdapter: avoid binary-float artifacts leaking into a
        // number the user reads as a bill amount.
        let amount = Decimal(string: String(format: "%.6f", decoded.data.usageMonthly)) ?? Decimal(decoded.data.usageMonthly)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monthStartComponents = calendar.dateComponents([.year, .month], from: now)
        let monthStart = calendar.date(from: monthStartComponents) ?? now

        let record = SpendRecord(
            provider: .openrouter,
            attributionID: decoded.data.label ?? "self",
            attributionKind: .apiKey,
            model: nil,
            day: monthStart,
            amountUSD: amount,
            polledAt: Date()
        )

        return .success([record])
    }
}
