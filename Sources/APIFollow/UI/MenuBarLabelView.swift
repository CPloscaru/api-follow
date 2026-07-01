import SwiftUI

/// The always-visible menu bar text — deliberately dense (multiple
/// segments in one label) per explicit request: OpenRouter balance,
/// fal.ai balance, Claude session/weekly %, each shown only once that
/// provider actually has data (never a placeholder "$0.00" for an
/// unconfigured provider, which would misrepresent "no data yet" as
/// "zero balance").
struct MenuBarLabelView: View {
    @ObservedObject var snapshot: SpendSnapshotStore
    @ObservedObject var claudePlanSnapshot: ClaudePlanSnapshotStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: snapshot.overallReliability.systemImageName)
            if segments.isEmpty {
                Text(Self.formatAmount(snapshot.monthToDateTotal))
            } else {
                Text(segments.joined(separator: " · "))
            }
        }
    }

    private var segments: [String] {
        var parts: [String] = []
        if let balance = snapshot.balances[.openrouter] {
            parts.append("OR \(Self.formatAmount(balance))")
        }
        if let balance = snapshot.balances[.fal] {
            parts.append("Fal \(Self.formatAmount(balance))")
        }
        if let usage = claudePlanSnapshot.usage {
            parts.append("C \(Int(usage.sessionPercentage))%/\(Int(usage.weeklyPercentage))%")
        }
        return parts
    }

    private static func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = amount >= 100 ? 0 : 2
        return formatter.string(from: amount as NSDecimalNumber) ?? "$0"
    }
}
