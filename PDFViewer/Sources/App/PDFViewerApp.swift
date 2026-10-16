import SwiftUI
import UniformTypeIdentifiers

@main
struct PDFViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore.shared

    var body: some Scene {
        WindowGroup("PDF Viewer") {
            ContentView()
                .environmentObject(store)
                .onAppear {
                    // SwiftUI installs its own "Close" (Cmd+W) item that closes the window.
                    // We clear it once so our Cmd+W "Close Tab" item is the only Cmd+W.
                    MainMenuTweaks.apply()
                }
        }
        .defaultSize(width: 1240, height: 860)
        .windowToolbarStyle(.unified)
        .commands { appCommands }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        // "New" is useless here; keep "Open..." only.
        CommandGroup(replacing: .newItem) {
            Button("Open\u{2026}") {
                store.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("File") {
            Button("Close Tab") {
                store.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store.selectedTab == nil)
        }

        CommandMenu("View") {
            Button("Find\u{2026}") {
                store.beginFind()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Divider()

            Button(store.showThumbnails ? "Hide Thumbnails" : "Show Thumbnails") {
                store.toggleThumbnails()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Divider()

            Button("Zoom In") {
                store.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Zoom Out") {
                store.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Actual Size") {
                store.actualSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Fit to Width") {
                store.fitToWidth()
            }
            .disabled(store.selectedTab == nil)

            Divider()

            Button("Next Tab") {
                store.selectAdjacentTab(offset: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(store.tabs.count < 2)

            Button("Previous Tab") {
                store.selectAdjacentTab(offset: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(store.tabs.count < 2)
        }
    }
}