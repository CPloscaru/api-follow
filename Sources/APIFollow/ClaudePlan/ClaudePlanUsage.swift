import Foundation

/// Claude.ai plan usage — a fundamentally different data shape from
/// `SpendRecord` (rate-limit percentages, not dollar spend) obtained via
/// a fundamentally different mechanism (Claude Code's own OAuth token,
/// not this app's Admin API keys). Kept as a separate subsystem
/// deliberately, not force-fit into the SpendStore schema.
///
/// Only session (5h) and weekly (7d) percentages are populated — the
/// header-based technique this app uses (see ClaudePlanUsageFetcher)
/// does not expose per-model (Opus/Sonnet) breakdowns; that requires
/// the claude.ai session-cookie flow, which was explicitly not chosen
/// (see design doc decision — OAuth token over browser cookie).
struct ClaudePlanUsage: Equatable {
    var sessionPercentage: Double
    var sessionResetAt: Date
    var weeklyPercentage: Double
    var weeklyResetAt: Date
    var fetchedAt: Date
}

enum ClaudePlanFetchResult {
    case success(ClaudePlanUsage)
    /// Claude Code isn't installed/logged in on this machine — not an
    /// error, just nothing to show.
    case notAvailable
    case transientFailure(Error)
    case authError
}
