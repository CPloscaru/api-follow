import Foundation

/// Calls OpenRouter's Activity API (`GET /api/v1/activity`) — per-day,
/// per-model usage with a `usage` field in USD. Requires a Management
/// (Provisioning) key, NOT a regular OpenRouter API key: the two are
/// different credential types, and Management keys cannot even be used
/// to make completion requests (confirmed via official docs). Same
/// elevated-credential pattern as Anthropic/OpenAI Admin keys.
///
/// Attribution: the Activity API supports an `api_key_hash` FILTER
/// parameter, but its documented response items do not include an
/// `api_key_hash` FIELD — so without pre-computing and querying by each
/// tracked key's SHA-256 hash individually (a steady-state enhancement,
/// not v1), this app cannot reliably attribute spend to a specific key.
/// Treated as account-level, same `.workspace` attribution kind as
/// Anthropic, with a fixed "account" attribution ID.
struct OpenRouterAdapter: ProviderAdapter {
    let provider: Provider = .openrouter
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        // No date range parameter on this endpoint — omitting `date`
        // returns the last 30 completed UTC days in one response
        // (documented default), which comfortably covers the 5-min
        // polling loop's needs without per-day pagination.
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
                let providerName: String?

                enum CodingKeys: String, CodingKey {
                    case date, model, usage
                    case providerName = "provider_name"
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
                    polledAt: Date()
                )
            )
        }

        return .success(records)
    }
}
