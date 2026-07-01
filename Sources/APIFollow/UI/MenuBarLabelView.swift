import SwiftUI

/// The always-visible menu bar content — deliberately dense (multiple
/// segments in one label) per explicit request: OpenRouter balance,
/// fal.ai balance, Claude session/weekly %, each shown only once that
/// provider actually has data (never a placeholder "$0.00" for an
/// unconfigured provider, which would misrepresent "no data yet" as
/// "zero balance").
///
/// Uses a distinct SF Symbol + tint color per segment instead of text
/// prefixes ("OR", "Fal", "C") — icons are scannable at a glance without
/// reading, which plain abbreviated text isn't. No custom brand logos
/// (SF Symbols only has generic shapes, not third-party marks), so each
/// icon is a reasonable generic stand-in: a network glyph for
/// OpenRouter (it routes between providers), a photo-stack glyph for
/// fal.ai (image/video generation), and the sparkle already established
/// for Claude elsewhere in this app (the widget, MenuBarView's section).
struct MenuBarLabelView: View {
    /// Real finding from user feedback: with a crowded menu bar (many
    /// other system items), the full condensed text got silently
    /// clipped by macOS — the user saw only one segment, not a clean
    /// "shows what fits" degradation. Default OFF: icon + status color
    /// only, which is compact enough to never fight for space. Users
    /// who want the fuller text can opt in via the popover's settings
    /// gear, understanding their menu bar has room for it.
    static let showCondensedTextKey = "showCondensedMenuBarText"

    @ObservedObject var snapshot: SpendSnapshotStore
    @ObservedObject var claudePlanSnapshot: ClaudePlanSnapshotStore
    @AppStorage(MenuBarLabelView.showCondensedTextKey) private var showCondensedText = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: snapshot.overallReliability.systemImageName)
                .foregroundStyle(reliabilityColor)

            if showCondensedText {
                if segments.isEmpty {
                    Text(Self.formatAmount(snapshot.monthToDateTotal))
                } else {
                    ForEach(segments) { segment in
                        HStack(spacing: 2) {
                            Image(systemName: segment.icon)
                                .foregroundStyle(segment.color)
                            Text(segment.text)
                        }
                    }
                }
            }
        }
    }

    private struct Segment: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let text: String
    }

    private var segments: [Segment] {
        var parts: [Segment] = []
        if let balance = snapshot.balances[.openrouter] {
            parts.append(Segment(id: "or", icon: "network", color: .purple, text: Self.formatAmount(balance)))
        }
        if let balance = snapshot.balances[.fal] {
            parts.append(Segment(id: "fal", icon: "photo.stack", color: .teal, text: Self.formatAmount(balance)))
        }
        if let usage = claudePlanSnapshot.usage {
            parts.append(Segment(id: "claude", icon: "sparkle", color: .orange, text: "\(Int(usage.sessionPercentage))%·\(Int(usage.weeklyPercentage))%"))
        }
        return parts
    }

    private var reliabilityColor: Color {
        switch snapshot.overallReliability {
        case .ok: return .green
        case .syncing: return .orange
        case .needsAttention: return .red
        }
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = amount >= 100 ? 0 : 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0"
    }
}
