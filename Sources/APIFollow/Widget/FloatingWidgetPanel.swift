import AppKit
import SwiftUI

/// A borderless, non-activating, always-on-top panel — the closest
/// approximation of a "desktop widget" achievable without migrating to
/// a real WidgetKit extension (see design doc discussion: that requires
/// an Xcode project + App Group entitlements, a bigger lift than this
/// session's scope). Floats above normal windows, shows on every Space
/// (including full-screen apps), and never steals focus/activates the
/// app when clicked — behaves like a real widget, not a window.
final class FloatingWidgetPanel: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 160),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: rootView)
        contentView = hostingView
        setContentSize(hostingView.intrinsicContentSize)
    }

    // Non-activating panels don't normally accept key events, but we
    // still want the panel to receive mouse events for dragging.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
