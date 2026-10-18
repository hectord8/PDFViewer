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

            if let workbook = activeWorkbook, workbookHasOpenFiles(workbook) {
                WorkbookTabBar(workbook: workbook)
                    .id("workbook-tabs")

                Divider()
            }

            GeometryReader { geo in
                let widths = panelWidths(available: geo.size.width)

                HStack(spacing: 0) {
                    if store.showLibrary {
                        LibrarySidebar()
                            .frame(width: widths.library)
                        Divider()
                    }

                    if store.showAnnotations, !store.isGeneratedTabActive, let tab = store.selectedTab {
                        PageNotesPanel(tab: tab)
                            .id("annotation-\(tab.id)")
                            .frame(width: widths.notes)

                        PanelResizeHandle(side: .trailing, width: $store.notesPanelWidth, range: 180...560) {
                            store.persistPanelWidths()
                        }
                    }

                    content
                        .frame(minWidth: minContentWidth, maxWidth: .infinity, maxHeight: .infinity)
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            store.open(providers: providers)
                        }

                    if store.showAgentPanel {
                        PanelResizeHandle(side: .leading, width: $store.agentPanelWidth, range: 260...680) {
                            store.persistPanelWidths()
                        }

                        AgentChatPanel()
                            .id("agent-panel")
                            .frame(width: widths.agent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: minContentWidth + 120, minHeight: 480)
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
        if let id = workbooks.activeWorkbookID,
           let workbook = workbooks.workbooks.first(where: { $0.id == id }) {
            return workbook
        }
        // Fall back to the workbook that owns the document currently open.
        if let path = store.selectedTab?.url.path,
           let workbook = workbooks.workbooks.first(where: { $0.containsPath(path) }) {
            return workbook
        }
        return nil
    }

    /// Whether any of the workbook's files are open (so the strip is only shown
    /// when it actually has tabs, never as a permanent empty bar).
    private func workbookHasOpenFiles(_ workbook: Workbook) -> Bool {
        var paths: Set<String> = []
        func collect(_ folders: [WorkbookFolder], _ items: [WorkbookItem]) {
            for folder in folders { collect(folder.folders, folder.items) }
            paths.formUnion(items.map(\.path))
        }
        collect(workbook.folders, workbook.items)

        if store.tabs.contains(where: { paths.contains($0.url.path) }) { return true }
        if store.summaries.contains(where: { $0.fileURL.map { paths.contains($0.path) } ?? false }) { return true }
        if store.flashcards.contains(where: { $0.deckURL.map { paths.contains($0.path) } ?? false }) { return true }
        if store.quizzes.contains(where: { $0.fileURL.map { paths.contains($0.path) } ?? false }) { return true }
        return false
    }

    private let libraryWidth: CGFloat = 240
    private let minLibraryWidth: CGFloat = 180
    private let minNotesWidth: CGFloat = 150
    private let minAgentWidth: CGFloat = 220
    private let minContentWidth: CGFloat = 360

    /// Shrinks the side panels so the document always keeps a usable width,
    /// and restores the preferred widths when the window grows again.
    private func panelWidths(available: CGFloat) -> (library: CGFloat, notes: CGFloat, agent: CGFloat) {
        let showingNotes = store.showAnnotations && !store.isGeneratedTabActive && store.selectedTab != nil

        var library = store.showLibrary ? libraryWidth : 0
        var notes = showingNotes ? CGFloat(store.notesPanelWidth) : 0
        var agent = store.showAgentPanel ? CGFloat(store.agentPanelWidth) : 0

        var overflow = library + notes + agent + minContentWidth - available

        if overflow > 0, showingNotes {
            let reduce = min(overflow, notes - minNotesWidth)
            if reduce > 0 { notes -= reduce; overflow -= reduce }
        }
        if overflow > 0, store.showAgentPanel {
            let reduce = min(overflow, agent - minAgentWidth)
            if reduce > 0 { agent -= reduce; overflow -= reduce }
        }
        if overflow > 0, store.showLibrary {
            let reduce = min(overflow, library - minLibraryWidth)
            if reduce > 0 { library -= reduce; overflow -= reduce }
        }

        return (library, notes, agent)
    }

    @ViewBuilder
    private var content: some View {
        if store.showWorkbookChat {
            WorkbookChatView()
                .id("workbook-chat")
        } else if let summary = store.selectedSummaryTab {
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

            Button {
                store.toggleWorkbookChat()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right")
            }
            .help("Workbook Assistant")

            Button {
                TodoWindowController.shared.toggle()
            } label: {
                Image(systemName: "checklist")
            }
            .help("Tasks")
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
