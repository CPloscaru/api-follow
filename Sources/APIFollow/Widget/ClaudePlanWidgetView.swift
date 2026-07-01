import SwiftUI

/// Compact content for the floating desktop widget — same data as
/// MenuBarView's Claude Plan section, denser layout since this view has
/// to stand alone on the desktop rather than sit inside a popover with
/// other context around it.
struct ClaudePlanWidgetView: View {
    @ObservedObject var claudePlanSnapshot: ClaudePlanSnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkle")
                    .foregroundStyle(.orange)
                Text("Claude")
                    .font(.headline)
                Spacer()
            }

            if let usage = claudePlanSnapshot.usage {
                bar(label: "Session (5h)", percentage: usage.sessionPercentage, resetAt: usage.sessionResetAt)
                bar(label: "Weekly", percentage: usage.weeklyPercentage, resetAt: usage.weeklyResetAt)
            } else {
                Text(claudePlanSnapshot.isAvailable ? "Loading…" : "Claude Code not found on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 220)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private func bar(label: String, percentage: Double, resetAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text("\(Int(percentage))%")
                    .font(.caption)
                    .bold()
                    .monospacedDigit()
            }
            ProgressView(value: min(max(percentage, 0), 100), total: 100)
                .tint(percentage >= 90 ? .red : (percentage >= 75 ? .orange : .green))
            Text("Resets \(resetAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
