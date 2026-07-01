import Foundation

/// Calls OpenRouter's Activity API (`GET /api/v1/activity`) — per-day,
/// per-model usage with request counts and token breakdowns.
///
/// **Revised again (2026-07-01):** the design initially assumed a
/// Management (Provisioning) key was required and used this endpoint;
/// then, after the user reported no Management key was available on
/// their account, this was swapped for the poorer self-key `/api/v1/key`
/// endpoint (monthly total only, no model/token detail). The user then
/// confirmed they DO have Management key access after all (it was just
/// not where they expected in the OpenRouter settings) — so this reverts
/// to the Activity API, which is what actually satisfies the original
/// ask: total spend, request counts, per-model breakdown, and prompt/
/// completion/reasoning token counts, matching what OpenRouter's own
/// Activity page shows.
///
/// Auth: header `Authorization: Bearer <management_key>` — a Management
/// key, NOT a regular OpenRouter API key (confirmed via official docs;
/// Management keys can't even be used for completion requests).
///
/// Attribution: the Activity API's documented response items do not
/// include an `api_key_hash` FIELD (only a query-parameter FILTER by
/// SHA-256 hash) — so this is still treated as account-level
/// attribution (`.workspace` kind, "account" ID), same as Anthropic.
/// Per-key attribution would require pre-computing each tracked key's
/// hash and issuing one filtered request per key — a steady-state
/// enhancement, not v1.
struct OpenRouterAdapter: ProviderAdapter {
    let provider: Provider = .openrouter
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        // No date range parameter — omitting `date` returns the last 30
        // completed UTC days in one response (documented default).
        let url = URL(string: "https://openrouter.ai/api/v1/activity")!

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

        return Self.parse(data)
    }

    /// Strict parsing (D8) — see AnthropicAdapter.parse for rationale.
    static func parse(_ data: Data) -> FetchResult {
        struct Response: Decodable {
            struct Item: Decodable {
                let date: String
                let model: String?
                let usage: Double
                let requests: Int?
                let promptTokens: Int?
                let completionTokens: Int?
                let reasoningTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case date, model, usage, requests
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                    case reasoningTokens = "reasoning_tokens"
                }
            }
            let data: [Item]
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return .parseError(error)
        }

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone(identifier: "UTC")

        var records: [SpendRecord] = []
        for item in decoded.data {
            guard let day = dayFormatter.date(from: item.date) else {
                return .parseError(ProviderAdapterError.missingField("date not parseable: \(item.date)"))
            }
            guard item.usage.isFinite, item.usage >= 0 else {
                return .parseError(ProviderAdapterError.invalidAmount("non-finite or negative usage: \(item.usage)"))
            }
            // Same double->decimal precision guard as OpenAIAdapter.
            let amount = Decimal(string: String(format: "%.6f", item.usage)) ?? Decimal(item.usage)

            records.append(
                SpendRecord(
                    provider: .openrouter,
                    attributionID: "account",
                    attributionKind: .workspace,
                    model: item.model,
                    day: day,
                    amountUSD: amount,
                    polledAt: Date(),
                    requests: item.requests,
                    promptTokens: item.promptTokens,
                    completionTokens: item.completionTokens,
                    reasoningTokens: item.reasoningTokens
                )
            )
        }

        return .success(records)
    }
}
