import Foundation

/// Calls Apify's monthly usage API (`GET /v2/users/me/usage/monthly`) for
/// per-day spend. Account-level personal API token — no admin/regular key
/// split like the other providers (Apify has no such distinction), and
/// account-wide attribution (`.workspace`), same as fal.ai/Anthropic.
///
/// The endpoint returns the single billing cycle CONTAINING the `date`
/// query param, not an arbitrary range — passing `until` gets the current
/// cycle. Days from `since` that fall in an earlier cycle are simply
/// absent from `dailyServiceUsages` and get filtered out below, same
/// "best effort over the requested window" behavior as every other
/// adapter here (D8: don't guess a number for what wasn't returned).
struct ApifyAdapter: ProviderAdapter {
    let provider: Provider = .apify
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        var components = URLComponents(string: "https://api.apify.com/v2/users/me/usage/monthly")!
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        components.queryItems = [URLQueryItem(name: "date", value: dayFormatter.string(from: until))]

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

        return Self.parse(data, since: since, until: until)
    }

    /// Strict parsing (D8) — see AnthropicAdapter.parse for rationale.
    /// `internal` so unit tests can exercise it directly against fixture
    /// JSON, no network.
    static func parse(_ data: Data, since: Date, until: Date) -> FetchResult {
        struct Response: Decodable {
            struct Daily: Decodable {
                let date: String
                let totalUsageCreditsUsd: Double
            }
            struct Payload: Decodable {
                let dailyServiceUsages: [Daily]
            }
            let data: Payload
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return .parseError(error)
        }

        // Apify's dates carry fractional seconds ("2022-10-02T00:00:00.000Z"),
        // which the default ISO8601DateFormatter (no fractional-seconds
        // option) can't parse — fall back to a plain-format attempt for
        // resilience against a response without the trailing ".000".
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()

        var records: [SpendRecord] = []
        for daily in decoded.data.dailyServiceUsages {
            guard let day = fractionalFormatter.date(from: daily.date) ?? plainFormatter.date(from: daily.date) else {
                return .parseError(ProviderAdapterError.missingField("date not parseable: \(daily.date)"))
            }
            guard day >= since, day <= until else { continue }
            guard daily.totalUsageCreditsUsd.isFinite, daily.totalUsageCreditsUsd >= 0 else {
                return .parseError(ProviderAdapterError.invalidAmount("non-finite or negative cost: \(daily.totalUsageCreditsUsd)"))
            }
            let amount = Decimal(string: String(format: "%.6f", daily.totalUsageCreditsUsd)) ?? Decimal(daily.totalUsageCreditsUsd)

            records.append(
                SpendRecord(
                    provider: .apify,
                    attributionID: "account",
                    attributionKind: .workspace,
                    model: nil,
                    day: day,
                    amountUSD: amount,
                    polledAt: Date()
                )
            )
        }

        return .success(records)
    }
}
