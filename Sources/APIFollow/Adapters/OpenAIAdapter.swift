import Foundation

/// Calls OpenAI's Costs API (`GET /organization/costs`).
///
/// Unlike Anthropic, OpenAI DOES support real per-API-key attribution via
/// `group_by=api_key_id` (confirmed via official docs — design doc
/// Reviewer Concern #1, resolved).
struct OpenAIAdapter: ProviderAdapter {
    let provider: Provider = .openai
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(since.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(until.timeIntervalSince1970))),
            URLQueryItem(name: "group_by", value: "api_key_id"),
            URLQueryItem(name: "limit", value: "31"),
        ]

        var request = URLRequest(url: components.url!)
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

    /// Strict parsing (D8) — see AnthropicAdapter.parse for the same
    /// rationale. `internal` so tests can exercise it against fixture
    /// JSON directly.
    static func parse(_ data: Data) -> FetchResult {
        struct Response: Decodable {
            struct Bucket: Decodable {
                let startTime: Int
                let results: [Result]
                enum CodingKeys: String, CodingKey {
                    case startTime = "start_time"
                    case results
                }
            }
            struct Result: Decodable {
                let amount: Amount
                let apiKeyId: String?
                enum CodingKeys: String, CodingKey {
                    case amount
                    case apiKeyId = "api_key_id"
                }
            }
            struct Amount: Decodable {
                let value: Double
                let currency: String
            }
            let data: [Bucket]
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return .parseError(error)
        }

        var records: [SpendRecord] = []

        for bucket in decoded.data {
            let day = Date(timeIntervalSince1970: TimeInterval(bucket.startTime))
            for result in bucket.results {
                // Case-insensitive: OpenAI's docs don't pin down the exact
                // casing ("usd" vs "USD") precisely enough to hardcode one —
                // safer to accept either than to risk a false parseError
                // triggering on every real response due to a doc-reading gap.
                guard result.amount.currency.lowercased() == "usd" else {
                    return .parseError(ProviderAdapterError.invalidAmount("unexpected currency: \(result.amount.currency)"))
                }
                // OpenAI returns amount.value as a Double, not a decimal
                // string like Anthropic — round-trip through a formatted
                // string to avoid binary-float artifacts (e.g. 0.1 + 0.2)
                // leaking into a value users see as a bill amount.
                let amount = Decimal(string: String(format: "%.6f", result.amount.value)) ?? Decimal(result.amount.value)

                records.append(
                    SpendRecord(
                        provider: .openai,
                        attributionID: result.apiKeyId ?? "no-api-key-id",
                        attributionKind: .apiKey,
                        model: nil,
                        day: day,
                        amountUSD: amount,
                        polledAt: Date()
                    )
                )
            }
        }

        return .success(records)
    }
}
