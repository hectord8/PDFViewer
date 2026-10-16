import AppKit

/// AppKit processes menu key equivalents before the window gets a look at them,
/// so a `Button("Close Tab").keyboardShortcut("w")` in SwiftUI would lose the race
/// against SwiftUI's built-in "Close" item. Disabling that built-in item leaves
/// Cmd+W as ours.
enum MainMenuTweaks {

    static func apply() {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" }),
              let items = fileMenu.submenu?.items else { return }

        for item in items where item.action == #selector(NSWindow.performClose(_:)) {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }
}