import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// The always-visible menu bar content. Two tiers:
/// - Always shown: the app icon (a Lucide "volleyball" SVG — ISC
///   licensed, see Resources/menubar-icon.svg for attribution — chosen
///   over an SF Symbol per explicit request for something more
///   distinctive than a generic system glyph) tinted by overall
///   reliability, plus the month-to-date SPEND total. One compact
///   number, low risk of the menu bar clipping it.
/// - Opt-in (settings gear in the popover, default off): the fuller
///   per-provider breakdown — OpenRouter balance, fal.ai balance,
///   Claude session/weekly %, each shown only once that provider
///   actually has data (never a placeholder "$0.00" for an
///   unconfigured provider). This is the part that got silently
///   clipped on a crowded menu bar before it was made opt-in.
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
            menuBarIcon
                .foregroundStyle(reliabilityColor)

            // Total month-to-date SPEND — always visible, not gated
            // behind the settings toggle. This is one compact number
            // (unlike the multi-segment breakdown below), so it never
            // risks the clipping problem that made the fuller text
            // opt-in in the first place.
            Text(Self.formatAmount(snapshot.monthToDateTotal))

            if showCondensedText {
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

    /// Loads Resources/menubar-icon.svg as a template (tintable) image
    /// via `Bundle.module`, falling back to an SF Symbol if SVG loading
    /// fails for any reason (older macOS SVG rasterization quirks,
    /// resource not found, etc.) — the menu bar should never end up
    /// with a blank icon.
    @ViewBuilder
    private var menuBarIcon: some View {
        #if canImport(AppKit)
        if let nsImage = Self.cachedIcon {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "banknote.fill")
        }
        #else
        Image(systemName: "banknote.fill")
        #endif
    }

    #if canImport(AppKit)
    /// Reads straight from Contents/Resources/ (standard macOS app
    /// bundle layout), not SPM's Bundle.module — see Package.swift's
    /// comment on Resources/menubar-icon.svg for why. Falls back to
    /// nil (→ SF Symbol) when run as a bare `swift run`/`swift build`
    /// binary rather than the packaged .app from build-app.sh, since
    /// there's no Contents/Resources in that context.
    private static let cachedIcon: NSImage? = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("menubar-icon.svg"),
              let image = NSImage(contentsOf: url)
        else {
            return nil
        }
        image.isTemplate = true // tintable via .foregroundStyle, matches SF Symbol behavior
        return image
    }()
    #endif

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
        formatter.locale = .appDisplay
        formatter.maximumFractionDigits = amount >= 100 ? 0 : 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0"
    }
}
