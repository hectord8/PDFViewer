import AppKit
import SwiftUI

/// A small floating panel for the task list. It can be moved anywhere and
/// stays on top of the app's windows.
@MainActor
final class TodoWindowController {
    static let shared = TodoWindowController()

    private var panel: NSPanel?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 380),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Tasks"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: TodoListView())

        if !panel.setFrameUsingName("TodoPanel") {
            positionTopRight(panel)
        }
        panel.setFrameAutosaveName("TodoPanel")
        return panel
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24)
        )
    }
}
