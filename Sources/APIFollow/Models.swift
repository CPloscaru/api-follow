import Foundation

/// v1 (MVP) scope per design doc: Anthropic + OpenAI only.
/// OpenRouter, Mistral, fal.ai are steady-state additions behind the
/// generic adapter interface (design doc Next Steps #4).
enum Provider: String, CaseIterable, Codable, Sendable {
    case anthropic
    case openai
    case openrouter
}

/// Anthropic's Cost API only supports workspace-level grouping (no
/// per-API-key breakdown); OpenAI's Costs API supports real per-key
/// attribution. The attribution unit is therefore per-provider, not a
/// single universal shape — see design doc Reviewer Concern #1 (resolved).
enum AttributionKind: String, Codable, Sendable {
    case apiKey
    case workspace
}

struct SpendRecord: Codable, Sendable, Equatable {
    var provider: Provider
    var attributionID: String
    var attributionKind: AttributionKind
    var model: String?
    /// Calendar day (UTC midnight) this spend bucket covers.
    var day: Date
    var amountUSD: Decimal
    var polledAt: Date
}

/// The four "not current" states from design doc decision D6. Distinct
/// states exist because they imply different remediation: transient and
/// rate-limited resolve themselves; auth-error and parse-error do not
/// resolve without human/developer action.
enum ProviderStatus: Equatable, Sendable {
    case ok(lastPolledAt: Date)
    case staleTransient(lastPolledAt: Date?)
    case staleRateLimited(lastPolledAt: Date?)
    case staleAuthError(lastPolledAt: Date?)
    case staleParseError(lastPolledAt: Date?)

    /// D12: auth-error and parse-error never resolve without action —
    /// they get the distinct "needs your attention" badge family.
    var needsAttention: Bool {
        switch self {
        case .staleAuthError, .staleParseError:
            return true
        case .ok, .staleTransient, .staleRateLimited:
            return false
        }
    }

    var isStale: Bool {
        if case .ok = self { return false }
        return true
    }
}

/// The result of a single provider fetch attempt — either a set of parsed
/// records, or a classified failure (D6/D8).
enum FetchResult {
    case success([SpendRecord])
    case transientFailure(Error)
    case rateLimited(retryAfter: Date?)
    case authError
    case parseError(Error)
}
