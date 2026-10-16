import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            DocumentTabBar()
                .id("tabbar")

            Divider()

            ZStack {
                if let tab = store.selectedTab {
                    PDFViewerPane(tab: tab)
                        .id(tab.id)
                        .toolbar { paneToolbar(for: tab) }
                } else {
                    WelcomeView()
                        .id("welcome")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            store.open(providers: providers)
        }
        .alert(
            "Couldn’t Open File",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            ),
            presenting: store.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    @ToolbarContentBuilder
    private func paneToolbar(for tab: PDFDocumentTab) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.toggleThumbnails()
            } label: {
                Image(systemName: "sidebar.squares.left")
            }
            .help("Show or hide the thumbnail sidebar")

            Button {
                store.beginFind()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Find text in this document (⌘F)")
        }

        ToolbarItem(placement: .principal) {
            Text("Page \(tab.pageIndex + 1) of \(tab.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 130)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (⌘−)")

            Button {
                store.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+)")

            Button {
                store.fitToWidth()
            } label: {
                Image(systemName: "arrow.left.and.right")
            }
            .help("Fit to width")
        }
    }
}