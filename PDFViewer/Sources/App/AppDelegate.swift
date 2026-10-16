import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Files dropped on the Dock icon land here, as do "Open With" requests and
    /// double-clicks in Finder. macOS launches the app first if it isn't running.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        LibraryStore.shared.open(urls: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LibraryStore.shared.restoreSessionIfNeeded()
    }

    /// Save immediately, without waiting for the debounce timer.
    func applicationWillTerminate(_ notification: Notification) {
        LibraryStore.shared.saveSessionNow()
        MainActor.assumeIsolated {
            AgentChatModel.shared.stopServer()
        }
    }

    /// Quit when the last window closes, like a normal document app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}