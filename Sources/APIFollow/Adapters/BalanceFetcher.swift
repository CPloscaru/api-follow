import Foundation

/// Remaining credit balance — a different concept from `SpendRecord`
/// (historical spend). Only OpenRouter and fal.ai have a prepaid-credit
/// model where "remaining balance" is meaningful; Anthropic and OpenAI
/// are billed pay-as-you-go against a card, with no equivalent single
/// "credits remaining" figure exposed the same way. Scoped to the two
/// providers that actually have this, not force-fit onto all four.
enum BalanceFetchResult {
    case success(Decimal)
    case authError
    case transientFailure(Error)
    case parseError(Error)
}

protocol BalanceFetcher: Sendable {
    func fetchBalance(adminKey: String) async -> BalanceFetchResult
}

/// `GET /api/v1/credits` — confirmed via official docs earlier this
/// session (design doc D-series decisions on OpenRouter). Balance =
/// total_credits - total_usage; the endpoint itself doesn't return a
/// single "remaining" field, so this computes it.
struct OpenRouterBalanceFetcher: BalanceFetcher {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchBalance(adminKey: String) async -> BalanceFetchResult {
        let url = URL(string: "https://openrouter.ai/api/v1/credits")!
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
        if http.statusCode == 401 || http.statusCode == 403 {
            return .authError
        }
        guard http.statusCode == 200 else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(http.statusCode))
        }

        return Self.parse(data)
    }

    static func parse(_ data: Data) -> BalanceFetchResult {
        struct Response: Decodable {
            struct Data: Decodable {
                let totalCredits: Double
                let totalUsage: Double
                enum CodingKeys: String, CodingKey {
                    case totalCredits = "total_credits"
                    case totalUsage = "total_usage"
                }
            }
            let data: Data
        }

        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let remaining = decoded.data.totalCredits - decoded.data.totalUsage
            let amount = Decimal(string: String(format: "%.6f", remaining)) ?? Decimal(remaining)
            return .success(amount)
        } catch {
            return .parseError(error)
        }
    }
}

/// `GET /v1/account/billing?expand=credits` — confirmed via official
/// docs (2026-07-02, same research pass that found fal.ai's real Usage
/// API). Without `expand=credits` the `credits` object is omitted
/// entirely, per the documented example.
struct FalBalanceFetcher: BalanceFetcher {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchBalance(adminKey: String) async -> BalanceFetchResult {
        var components = URLComponents(string: "https://api.fal.ai/v1/account/billing")!
        components.queryItems = [URLQueryItem(name: "expand", value: "credits")]

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
        if http.statusCode == 401 || http.statusCode == 403 {
            return .authError
        }
        guard http.statusCode == 200 else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(http.statusCode))
        }

        return Self.parse(data)
    }

    static func parse(_ data: Data) -> BalanceFetchResult {
        struct Response: Decodable {
            struct Credits: Decodable {
                let currentBalance: Double
                let currency: String
                enum CodingKeys: String, CodingKey {
                    case currentBalance = "current_balance"
                    case currency
                }
            }
            let credits: Credits?
        }

        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let credits = decoded.credits else {
                // `credits` omitted entirely — the account has no
                // credit-balance concept enabled, not an error.
                return .parseError(ProviderAdapterError.missingField("credits object absent from response"))
            }
            guard credits.currency.uppercased() == "USD" else {
                return .parseError(ProviderAdapterError.invalidAmount("unexpected currency: \(credits.currency)"))
            }
            let amount = Decimal(string: String(format: "%.6f", credits.currentBalance)) ?? Decimal(credits.currentBalance)
            return .success(amount)
        } catch {
            return .parseError(error)
        }
    }
}

/// `GET /v2/users/me/limits` — confirmed via official docs (2026-07-02).
/// Apify's model isn't prepaid credits like OpenRouter/fal.ai, it's a
/// monthly spending cap (`limits.maxMonthlyUsageUsd`) against usage this
/// billing cycle (`current.monthlyUsageUsd`); "remaining" here is computed
/// the same way as OpenRouter's (cap minus usage) so it slots into the
/// existing "X left" balance row without any UI changes.
struct ApifyBalanceFetcher: BalanceFetcher {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSession.shared) {
        self.httpClient = httpClient
    }

    func fetchBalance(adminKey: String) async -> BalanceFetchResult {
        let url = URL(string: "https://api.apify.com/v2/users/me/limits")!
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
        if http.statusCode == 401 || http.statusCode == 403 {
            return .authError
        }
        guard http.statusCode == 200 else {
            return .transientFailure(ProviderAdapterError.unexpectedStatus(http.statusCode))
        }

        return Self.parse(data)
    }

    static func parse(_ data: Data) -> BalanceFetchResult {
        struct Response: Decodable {
            struct Limits: Decodable {
                let maxMonthlyUsageUsd: Double
            }
            struct Current: Decodable {
                let monthlyUsageUsd: Double
            }
            struct Payload: Decodable {
                let limits: Limits
                let current: Current
            }
            let data: Payload
        }

        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let remaining = decoded.data.limits.maxMonthlyUsageUsd - decoded.data.current.monthlyUsageUsd
            let amount = Decimal(string: String(format: "%.6f", remaining)) ?? Decimal(remaining)
            return .success(amount)
        } catch {
            return .parseError(error)
        }
    }
}
