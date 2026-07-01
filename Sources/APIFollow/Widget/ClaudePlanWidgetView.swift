import SwiftUI

/// Compact content for the floating desktop widget — same data as
/// MenuBarView's Claude Plan section, denser layout since this view has
/// to stand alone on the desktop rather than sit inside a popover with
/// other context around it.
struct ClaudePlanWidgetView: View {
    @ObservedObject var claudePlanSnapshot: ClaudePlanSnapshotStore
    /// Closes the floating panel. Injected rather than reaching back
    /// into `FloatingWidgetController` directly — this view has no
    /// business knowing how it's hosted (panel vs. some future
    /// presentation), just that "close" is a thing it can ask for.
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkle")
                    .foregroundStyle(.orange)
                Text("Claude")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await claudePlanSnapshot.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(claudePlanSnapshot.isRefreshing)
                .help("Refresh now — sends one tiny real message to check current usage")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Hide widget")
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
