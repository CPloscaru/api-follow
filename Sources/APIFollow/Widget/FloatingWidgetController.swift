import AppKit
import Combine

/// Owns the floating overlay panel's lifecycle: show/hide, and
/// remembering where the user dragged it so it reopens in the same
/// spot. AppKit (`NSPanel`/`NSScreen`) is main-thread-only, so this
/// whole controller is MainActor-isolated.
///
/// Generalized from an earlier Claude-only widget per direct user
/// request — the panel now shows everything connected (spend snapshot
/// + Claude plan), not just Claude.
@MainActor
final class FloatingWidgetController: ObservableObject {
    @Published private(set) var isVisible = false

    private var panel: FloatingWidgetPanel?
    private let snapshot: SpendSnapshotStore
    private let claudePlanSnapshot: ClaudePlanSnapshotStore
    private static let positionDefaultsKey = "GlobalOverlay.origin"

    init(snapshot: SpendSnapshotStore, claudePlanSnapshot: ClaudePlanSnapshotStore) {
        self.snapshot = snapshot
        self.claudePlanSnapshot = claudePlanSnapshot
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel: FloatingWidgetPanel
        if let existing = self.panel {
            panel = existing
        } else {
            let view = GlobalOverlayView(snapshot: snapshot, claudePlanSnapshot: claudePlanSnapshot, onClose: { [weak self] in self?.hide() })
                .environment(\.locale, .appDisplay)
            panel = FloatingWidgetPanel(rootView: view)
            self.panel = panel
        }

        if let origin = Self.loadPosition() {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 260, y: frame.maxY - 260))
        }

        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        guard let panel else { return }
        Self.savePosition(panel.frame.origin)
        panel.orderOut(nil)
        isVisible = false
    }

    private static func savePosition(_ origin: NSPoint) {
        UserDefaults.standard.set(["x": origin.x, "y": origin.y], forKey: positionDefaultsKey)
    }

    private static func loadPosition() -> NSPoint? {
        guard let dict = UserDefaults.standard.dictionary(forKey: positionDefaultsKey),
              let x = dict["x"] as? Double, let y = dict["y"] as? Double
        else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }
}
