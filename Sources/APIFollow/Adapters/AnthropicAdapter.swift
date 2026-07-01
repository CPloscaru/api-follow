import Foundation

/// Calls Anthropic's Cost Report API (`/v1/organizations/cost_report`).
///
/// Design doc Reviewer Concern #1 (resolved via official docs, not
/// runtime discovery): this endpoint has NO per-API-key breakdown —
/// `group_by` only supports "description" or "workspace_id". The finest
/// attribution unit for Anthropic is the workspace, not the key.
///
/// Auth: header `x-api-key` (NOT `Authorization: Bearer` — that's for
/// OAuth tokens, a different auth path this app doesn't use).
struct AnthropicAdapter: ProviderAdapter {
    let provider: Provider = .anthropic
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult {
        let formatter = ISO8601DateFormatter()

        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: formatter.string(from: since)),
            URLQueryItem(name: "ending_at", value: formatter.string(from: until)),
            URLQueryItem(name: "group_by[]", value: "workspace_id"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")

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

    /// Strict parsing (D8): every field this app relies on is validated;
    /// any missing/malformed field surfaces `.parseError` rather than a
    /// best-effort partial number. `internal` (not `private`) so unit
    /// tests can exercise it directly against fixture JSON, no network.
    static func parse(_ data: Data) -> FetchResult {
        struct Response: Decodable {
            struct Bucket: Decodable {
                let startingAt: String
                let results: [Result]
                enum CodingKeys: String, CodingKey {
                    case startingAt = "starting_at"
                    case results
                }
            }
            struct Result: Decodable {
                let amount: String
                let currency: String
                let workspaceId: String?
                let description: String?
                enum CodingKeys: String, CodingKey {
                    case amount, currency, description
                    case workspaceId = "workspace_id"
                }
            }
            let data: [Bucket]
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            return .parseError(error)
        }

        let dayFormatter = ISO8601DateFormatter()
        var records: [SpendRecord] = []

        for bucket in decoded.data {
            guard let day = dayFormatter.date(from: bucket.startingAt) else {
                return .parseError(ProviderAdapterError.missingField("starting_at not parseable as date: \(bucket.startingAt)"))
            }
            for result in bucket.results {
                guard result.currency == "USD" else {
                    // Unexpected currency is exactly the kind of API-shape
                    // drift D8 exists to catch loud, not silently misreport.
                    return .parseError(ProviderAdapterError.invalidAmount("unexpected currency: \(result.currency)"))
                }
                guard let amount = Decimal(string: result.amount) else {
                    return .parseError(ProviderAdapterError.invalidAmount(result.amount))
                }
                records.append(
                    SpendRecord(
                        provider: .anthropic,
                        attributionID: result.workspaceId ?? "default",
                        attributionKind: .workspace,
                        model: nil, // not grouping by description in this query; add if steady-state wants per-model breakdown
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
