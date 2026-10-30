import AppKit
import SwiftUI

/// Small floating AI prompt panel. Starts at a fixed size, remembers the size
/// and position the user picks, and never resizes itself afterwards.
@MainActor
final class AIPromptWindowController {
    static let shared = AIPromptWindowController()

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
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI Prompt"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 240)

        let hostingView = NSHostingView(
            rootView: AIPromptView()
                .environmentObject(AgentChatModel.shared)
                .environmentObject(LibraryStore.shared)
        )
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        if !panel.setFrameUsingName("AIPromptPanel") {
            positionBottomRight(panel)
        }
        panel.setFrameAutosaveName("AIPromptPanel")
        return panel
    }

    private func positionBottomRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(
            NSPoint(x: visible.maxX - size.width - 24, y: visible.minY + 24)
        )
    }
}
