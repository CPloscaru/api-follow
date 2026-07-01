import Foundation

/// v1 (MVP): a plain Swift protocol, one conformer per provider. The
/// steady-state declarative config+mapper system (design doc Premise #3,
/// justified in D16 for open-source contributor accessibility) builds on
/// top of this once 2+ providers are proven — not before (design doc
/// Next Steps).
protocol ProviderAdapter: Sendable {
    var provider: Provider { get }

    /// Fetches and STRICTLY parses spend data (D8) — any response that
    /// doesn't match the expected shape surfaces `.parseError` rather
    /// than a best-effort partial/guessed number. Never throws; all
    /// failure modes are represented in `FetchResult` so callers (the
    /// poller) always get an explicit classification (D6).
    func fetchSpend(adminKey: String, since: Date, until: Date) async -> FetchResult
}

/// Shared HTTP status → FetchResult classification (D6). Unexpected status
/// codes (anything not 200/401/403/429/5xx) are treated as parse errors:
/// they represent the API behaving in a way this app doesn't understand,
/// which is exactly the "don't guess, surface it" category D8 exists for.
enum HTTPClassifier {
    static func classify(statusCode: Int, retryAfterHeader: String?) -> FetchResult? {
        switch statusCode {
        case 200:
            return nil // caller proceeds to parse the body
        case 401, 403:
            return .authError
        case 429:
            return .rateLimited(retryAfter: parseRetryAfter(retryAfterHeader))
        case 500...599:
            return .transientFailure(ProviderAdapterError.serverError(statusCode))
        default:
            return .parseError(ProviderAdapterError.unexpectedStatus(statusCode))
        }
    }

    private static func parseRetryAfter(_ header: String?) -> Date? {
        guard let header, let seconds = TimeInterval(header) else { return nil }
        return Date().addingTimeInterval(seconds)
    }
}

enum ProviderAdapterError: Error {
    case serverError(Int)
    case unexpectedStatus(Int)
    case missingField(String)
    case invalidAmount(String)
}
