import Foundation

/// Calls fal.ai's Usage API (`GET /v1/models/usage`) — per-day (or any
/// timeframe), per-model breakdown, with real cost data.
///
/// **This reverses the design doc's original premise for fal.ai**
/// (Premises #1/#2), which assumed fal.ai had no spend-history API at
/// all and would need a code-level log-and-forward wrapper around the
/// user's own fal.ai calls. That assumption was wrong — verified against
/// official docs (2026-07-02): fal.ai has a real Usage API, same
/// elevated-credential pattern as every other provider here (an ADMIN-
/// scoped API key, distinct from a regular API-scoped key). fal.ai is
/// therefore a standard polled provider like Anthropic/OpenAI/
/// OpenRouter — no proxy, no wrapper, no exception to the "never sits
/// in the request path" premise.
///
/// Attribution: the endpoint supports an `api_key_id` FILTER parameter
/// (same shape as OpenRouter's `api_key_hash`), but the documented
/// response items don't show a per-item key identifier field — treated
/// as account-level attribution (`.workspace` kind), consistent with
/// Anthropic/OpenRouter. `quantity`/`unit` (e.g. "4 images") are
/// intentionally NOT mapped into `SpendRecord.requests` — that field
/// implies API request counts, and fal.ai's billing unit isn't always
/// a request (video seconds, image counts, etc.) — mapping it in would
/// silently misrepresent what the number means.
struct FalAdapter: ProviderAdapter {
    let provider: Provider = .fal
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        var components = URLComponents(string: "https://api.fal.ai/v1/models/usage")!
        let formatter = ISO8601DateFormatter()
        components.queryItems = [
            URLQueryItem(name: "start", value: formatter.string(from: since)),
            URLQueryItem(name: "end", value: formatter.string(from: until)),
            URLQueryItem(name: "timeframe", value: "day"),
            URLQueryItem(name: "expand", value: "time_series"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Key \(adminKey)", forHTTPHeaderField: "Authorization")

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
            struct Bucket: Decodable {
                let bucket: String
                let results: [Result]
            }
            struct Result: Decodable {
                let endpointId: String
                let cost: Double
                let currency: String
                enum CodingKeys: String, CodingKey {
                    case endpointId = "endpoint_id"
                    case cost, currency
                }
            }
            let timeSeries: [Bucket]
            enum CodingKeys: String, CodingKey {
                case timeSeries = "time_series"
            }
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return .parseError(error)
        }

        let dayFormatter = ISO8601DateFormatter()
        var records: [SpendRecord] = []

        for bucket in decoded.timeSeries {
            guard let day = dayFormatter.date(from: bucket.bucket) else {
                return .parseError(ProviderAdapterError.missingField("bucket not parseable as date: \(bucket.bucket)"))
            }
            for result in bucket.results {
                guard result.currency.uppercased() == "USD" else {
                    return .parseError(ProviderAdapterError.invalidAmount("unexpected currency: \(result.currency)"))
                }
                guard result.cost.isFinite, result.cost >= 0 else {
                    return .parseError(ProviderAdapterError.invalidAmount("non-finite or negative cost: \(result.cost)"))
                }
                let amount = Decimal(string: String(format: "%.6f", result.cost)) ?? Decimal(result.cost)

                records.append(
                    SpendRecord(
                        provider: .fal,
                        attributionID: "account",
                        attributionKind: .workspace,
                        model: result.endpointId,
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
