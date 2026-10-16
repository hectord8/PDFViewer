import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore

    var body: some View {
        VStack(spacing: 0) {
            DocumentTabBar()
                .id("tabbar")

            Divider()

            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        store.open(providers: providers)
                    }

                if store.showAgentPanel {
                    Divider()
                    AgentChatPanel()
                        .id("agent-panel")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar { toolbarContent }
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

    @ViewBuilder
    private var content: some View {
        if let primary = store.selectedTab {
            if let secondary = store.secondaryTab {
                SplitLayout(primary: primary, secondary: secondary)
            } else {
                PDFViewerPane(tab: primary)
                    .id(primary.id)
            }
        } else {
            WelcomeView()
                .id("welcome")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let tab = store.activeTab {
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

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.toggleAgentPanel()
            } label: {
                Image(systemName: "sparkles")
            }
            .help("Ask opencode about this PDF")
        }
    }
}

private struct SplitLayout: View {
    @EnvironmentObject private var store: LibraryStore
    let primary: PDFDocumentTab
    let secondary: PDFDocumentTab

    private let dividerWidth: CGFloat = 8
    private let minFraction = 0.2
    private let maxFraction = 0.8

    var body: some View {
        GeometryReader { geo in
            let available = max(geo.size.width - dividerWidth, 1)
            let fraction = min(max(store.splitFraction, minFraction), maxFraction)
            let leftWidth = max(available * fraction, 1)
            let rightWidth = max(available - leftWidth, 1)

            HStack(spacing: 0) {
                PDFViewerPane(tab: primary, isFocused: store.focusedPane == .primary)
                    .frame(width: leftWidth)
                    .id(primary.id)

                divider(available: available)

                PDFViewerPane(tab: secondary, isFocused: store.focusedPane == .secondary)
                    .frame(width: rightWidth)
                    .id(secondary.id)
            }
            .coordinateSpace(name: "split")
        }
    }

    private func divider(available: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: dividerWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("split"))
                .onChanged { value in
                    let proposed = Double(value.location.x / available)
                    store.splitFraction = min(max(proposed, minFraction), maxFraction)
                }
                .onEnded { _ in
                    store.commitSplitLayout()
                }
        )
    }
}
