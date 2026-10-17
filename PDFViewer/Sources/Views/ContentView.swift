import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var agent: AgentChatModel
    @EnvironmentObject private var workbooks: WorkbookStore

    var body: some View {
        VStack(spacing: 0) {
            DocumentTabBar()
                .id("tabbar")

            Divider()

            if let workbook = activeWorkbook {
                WorkbookTabBar(workbook: workbook)
                    .id("workbook-tabs")

                Divider()
            }

            HStack(spacing: 0) {
                if store.showLibrary {
                    LibrarySidebar()
                        .frame(width: 240)
                    Divider()
                }

                if store.showAnnotations, !store.isGeneratedTabActive, let tab = store.selectedTab {
                    PageNotesPanel(tab: tab)
                        .id("annotation-\(tab.id)")
                        .frame(width: store.notesPanelWidth)

                    PanelResizeHandle(side: .trailing, width: $store.notesPanelWidth, range: 180...560) {
                        store.persistPanelWidths()
                    }
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        store.open(providers: providers)
                    }

                if store.showAgentPanel {
                    PanelResizeHandle(side: .leading, width: $store.agentPanelWidth, range: 260...680) {
                        store.persistPanelWidths()
                    }

                    AgentChatPanel()
                        .id("agent-panel")
                        .frame(width: store.agentPanelWidth)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .toolbar { toolbarContent }
        .onAppear {
            agent.refreshSavedDecks()
            agent.refreshSavedSummaries()
            agent.refreshSavedQuizzes()
        }
        .onChange(of: store.showAgentPanel) { _, _ in
            agent.refreshSavedDecks()
            agent.refreshSavedSummaries()
            agent.refreshSavedQuizzes()
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

    private var activeWorkbook: Workbook? {
        guard let id = workbooks.activeWorkbookID else { return nil }
        return workbooks.workbooks.first { $0.id == id }
    }

    @ViewBuilder
    private var content: some View {
        if let summary = store.selectedSummaryTab {
            SummaryView(tab: summary)
                .id(summary.id)
        } else if let deck = store.selectedFlashcardTab {
            FlashcardView(tab: deck)
                .id(deck.id)
        } else if let quiz = store.selectedQuizTab {
            QuizView(tab: quiz)
                .id(quiz.id)
        } else if let primary = store.selectedTab {
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
        ToolbarItemGroup(placement: .navigation) {
            Button {
                store.toggleLibrary()
            } label: {
                Image(systemName: "books.vertical")
            }
            .help("Show or hide the library")
        }

        if let tab = store.activeTab, !store.isGeneratedTabActive {
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

                Menu {
                    Button(store.showAnnotations ? "Hide Notes" : "Show Notes") {
                        store.toggleAnnotations()
                    }

                    Divider()

                    Button("Annotate All Pages") {
                        store.showAnnotations = true
                        Task { await agent.annotatePages(tab) }
                    }
                    .disabled(tab.isAnnotatingPages)

                    Button("Annotate This Page") {
                        store.showAnnotations = true
                        Task { await agent.annotateCurrentPage(tab) }
                    }
                    .disabled(tab.isAnnotatingPages)

                    Button("Clear Notes") {
                        tab.pageNotes.removeAll()
                    }
                    .disabled(tab.pageNotes.isEmpty)
                } label: {
                    Image(systemName: "text.bubble")
                }
                .help("Notes beside the page")
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
            .help("Ask opencode about this document")
        }
    }
}

private struct PanelResizeHandle: View {
    enum Side {
        case leading
        case trailing
    }

    let side: Side
    @Binding var width: Double
    let range: ClosedRange<Double>
    var onEnd: () -> Void = {}

    @State private var startWidth: Double?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if startWidth == nil { startWidth = width }
                    let base = startWidth ?? width
                    let delta = side == .leading ? -value.translation.width : value.translation.width
                    let newWidth = min(max(base + delta, range.lowerBound), range.upperBound)
                    if abs(newWidth - width) > 0.01 {
                        width = newWidth
                    }
                }
                .onEnded { _ in
                    startWidth = nil
                    onEnd()
                }
        )
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
