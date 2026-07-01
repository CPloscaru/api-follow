import AppKit
import Combine

/// Owns the floating widget panel's lifecycle: show/hide, and
/// remembering where the user dragged it so it reopens in the same
/// spot. AppKit (`NSPanel`/`NSScreen`) is main-thread-only, so this
/// whole controller is MainActor-isolated.
@MainActor
final class FloatingWidgetController: ObservableObject {
    @Published private(set) var isVisible = false

    private var panel: FloatingWidgetPanel?
    private let claudePlanSnapshot: ClaudePlanSnapshotStore
    private static let positionDefaultsKey = "ClaudePlanWidget.origin"

    init(claudePlanSnapshot: ClaudePlanSnapshotStore) {
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
            let view = ClaudePlanWidgetView(claudePlanSnapshot: claudePlanSnapshot)
            panel = FloatingWidgetPanel(rootView: view)
            self.panel = panel
        }

        if let origin = Self.loadPosition() {
            panel.setFrameOrigin(origin)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 240, y: frame.maxY - 200))
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
