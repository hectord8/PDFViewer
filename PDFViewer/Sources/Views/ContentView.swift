import SwiftUI

struct ContentView: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

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

                    VStack(spacing: 0) {
                        if let tab = store.activeTab, !store.isGeneratedTabActive {
                            DocumentControlsBar(tab: tab)
                            Divider()
                        }

                        content
                            .frame(minWidth: minContentWidth, maxWidth: .infinity, maxHeight: .infinity)
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                store.open(providers: providers)
                            }
                    }
                    .frame(minWidth: minContentWidth, maxWidth: .infinity, maxHeight: .infinity)

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
            store.restoreSessionIfNeeded()
            store.activateWorkbook(workbooks.activeWorkbookID)
            agent.refreshSavedDecks()
            agent.refreshSavedSummaries()
            agent.refreshSavedQuizzes()
        }
        .onChange(of: workbooks.activeWorkbookID) { oldValue, newValue in
            store.workbookChanged(from: oldValue, to: newValue)
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
        .hotReload()
    }

    private var activeWorkbook: Workbook? {
        guard let id = workbooks.activeWorkbookID else { return nil }
        return workbooks.workbooks.first(where: { $0.id == id })
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
            if reduce > 0 {
                notes -= reduce
                overflow -= reduce
            }
        }
        if overflow > 0, store.showAgentPanel {
            let reduce = min(overflow, agent - minAgentWidth)
            if reduce > 0 {
                agent -= reduce
                overflow -= reduce
            }
        }
        if overflow > 0, store.showLibrary {
            let reduce = min(overflow, library - minLibraryWidth)
            if reduce > 0 {
                library -= reduce
                overflow -= reduce
            }
        }

        return (library, notes, agent)
    }

    @ViewBuilder
    private var content: some View {
        if store.selectedLectureTab != nil {
            LecturePortalView()
                .id("lecture-portal")
        } else if let note = store.selectedNoteTab {
            NoteEditorView(note: note)
                .id(note.id)
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
            } else if store.isSplitPickerVisible {
                SplitPickerLayout(primary: primary)
            } else if let note = store.secondaryNoteTab {
                NoteSplitLayout(pdf: primary, note: note)
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
                Label("Library", systemImage: "books.vertical")
            }
            .help("Show or hide the library (⌘⌥L)")

            Button {
                store.openLecturePortal()
            } label: {
                Label("Lecture Portal", systemImage: "graduationcap")
            }
            .help("Lecture Portal (⌘⌥E)")

            Button {
                TodoWindowController.shared.toggle()
            } label: {
                Label("Tasks", systemImage: "checklist")
            }
            .help("Show or hide tasks")

            Button {
                store.newNote()
            } label: {
                Label("New Note", systemImage: "note.text")
            }
            .help("New note")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.toggleAgentPanel()
            } label: {
                Label("Assistant", systemImage: "sparkles")
            }
            .help("Assistant — ask about this page, document or workbook (⌘⌥A)")
        }
    }
}

/// Compact controls that sit directly above the document.
private struct DocumentControlsBar: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var agent: AgentChatModel
    @ObservedObject var tab: PDFDocumentTab

    var body: some View {
        HStack(spacing: 8) {
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

            if store.isSplit || store.isSplitPickerVisible {
                Button {
                    store.collapseSplit()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .help("Close split view")
            } else {
                Button {
                    store.beginSplitPicker()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .help("Open a file in split view")
            }

            Divider().frame(height: 16)

            Button {
                store.zoomOut()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom out (⌘−)")

            Text("Page \(tab.pageIndex + 1) of \(tab.pageCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 110)

            Button {
                store.zoomIn()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+)")

            Button {
                store.actualSize()
            } label: {
                Image(systemName: "1.magnifyingglass")
            }
            .help("Actual size (⌘0)")

            Button {
                store.fitToWidth()
            } label: {
                Image(systemName: "arrow.left.and.right")
            }
            .help("Fit to width")

            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.bar)
        .hotReload()
    }
}

/// A PDF on the left and an editable note on the right, sharing the draggable
/// split divider.
private struct NoteSplitLayout: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var store: LibraryStore
    let pdf: PDFDocumentTab
    let note: NoteTab

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
                PDFViewerPane(tab: pdf, isFocused: store.focusedPane == .primary)
                    .frame(width: leftWidth)
                    .id(pdf.id)

                divider(available: available)

                NoteEditorView(note: note)
                    .frame(width: rightWidth)
                    .id(note.id)
            }
            .coordinateSpace(name: "split")
        }
        .hotReload()
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

private struct PanelResizeHandle: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

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
        .hotReload()
    }
}

/// A PDF on the left and the split-file chooser on the right.
private struct SplitPickerLayout: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var store: LibraryStore
    let primary: PDFDocumentTab

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

                SplitPickerPane(primary: primary)
                    .frame(width: rightWidth)
            }
            .coordinateSpace(name: "split")
        }
        .hotReload()
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

private struct SplitPickerPane: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var store: LibraryStore
    let primary: PDFDocumentTab

    private var openTabs: [PDFDocumentTab] {
        store.tabs.filter { $0.id != primary.id }
    }

    private var openNotes: [NoteTab] {
        store.notes
    }

    private var recentTabs: [ClosedTab] {
        let openPaths = Set(store.tabs.map(\.url.path))
        var seen: Set<String> = [primary.url.path]
        var result: [ClosedTab] = []
        for recent in store.recentlyClosed.reversed() {
            guard !openPaths.contains(recent.url.path), !seen.contains(recent.url.path) else {
                continue
            }
            seen.insert(recent.url.path)
            result.append(recent)
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Open in Split View", systemImage: "rectangle.split.2x1")
                    .font(.headline)
                Spacer()
                Button {
                    store.cancelSplitPicker()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close the split picker")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if openTabs.isEmpty && openNotes.isEmpty && recentTabs.isEmpty {
                ContentUnavailableView(
                    "Nothing to split",
                    systemImage: "rectangle.split.2x1",
                    description: Text("Open another PDF or note first.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !openTabs.isEmpty {
                            sectionHeader("Open Tabs")
                            ForEach(openTabs) { tab in
                                pickerRow(
                                    icon: "doc.text",
                                    title: tab.title,
                                    subtitle: tab.url.deletingLastPathComponent().lastPathComponent
                                ) {
                                    store.chooseSecondaryTab(tab)
                                }
                            }
                        }

                        if !openNotes.isEmpty {
                            sectionHeader("Notes")
                            ForEach(openNotes) { note in
                                pickerRow(
                                    icon: "note.text",
                                    title: note.title,
                                    subtitle: "Note"
                                ) {
                                    store.chooseSecondaryNote(note)
                                }
                            }
                        }

                        if !recentTabs.isEmpty {
                            sectionHeader("Recently Opened")
                            ForEach(recentTabs, id: \.url.path) { recent in
                                pickerRow(
                                    icon: "clock.arrow.circlepath",
                                    title: recent.url.deletingPathExtension().lastPathComponent,
                                    subtitle: recent.url.deletingLastPathComponent().lastPathComponent
                                ) {
                                    store.openRecentAsSecondary(recent)
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .hotReload()
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .padding(.horizontal, 8)
    }

    private func pickerRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
        .hoverTint()
    }
}

private struct SplitLayout: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

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
        .hotReload()
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
