import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PDFViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore.shared
    @StateObject private var agent = AgentChatModel.shared
    @StateObject private var workbooks = WorkbookStore.shared

    var body: some Scene {
        WindowGroup("PDF Viewer") {
            ContentView()
                .environmentObject(store)
                .environmentObject(agent)
                .environmentObject(workbooks)
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

    // MARK: - Menu targets

    /// The PDF a tab-level command (pin, duplicate, reload, close others) acts on.
    /// Nil while a quiz, note, deck or other generated tab is in front.
    private var currentTab: PDFDocumentTab? {
        store.isGeneratedTabActive ? nil : store.selectedTab
    }

    /// The PDF pane a page, zoom, find or highlight command acts on (the focused
    /// pane when split). Nil while a generated tab is in front.
    private var focusedTab: PDFDocumentTab? {
        store.isGeneratedTabActive ? nil : store.activeTab
    }

    private var activeWorkbook: Workbook? {
        workbooks.workbooks.first { $0.id == workbooks.activeWorkbookID }
    }

    private var pinTitle: String {
        if let tab = currentTab, store.isPinned(tab) { return "Unpin Tab" }
        return "Pin Tab"
    }

    private var sidebarModeBinding: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "documentSidebarMode") ?? "pages" },
            set: { value in
                UserDefaults.standard.set(value, forKey: "documentSidebarMode")
                store.showThumbnails = true
            }
        )
    }

    private func promptGoToPage() {
        guard let tab = focusedTab else { return }
        guard
            let answer = MenuDialog.askText(
                title: "Go to Page",
                message: "Enter a page number from 1 to \(tab.pageCount).",
                placeholder: "Page number",
                initial: "\(tab.pageIndex + 1)",
                confirm: "Go"
            )
        else { return }

        guard let page = Int(answer), (1...tab.pageCount).contains(page) else {
            MenuDialog.info(title: "Page Not Found", message: "“\(answer)” isn’t a page in this document.")
            return
        }
        tab.go(toPageIndex: page - 1)
    }

    private func promptNewWorkbook() {
        guard
            let name = MenuDialog.askText(
                title: "New Workbook",
                message: "Name the new workbook.",
                placeholder: "Workbook name",
                confirm: "Create"
            )
        else { return }
        let workbook = workbooks.createWorkbook(named: name)
        workbooks.selectWorkbook(workbook.id)
    }

    private func promptRenameActiveWorkbook() {
        guard let workbook = activeWorkbook else { return }
        guard
            let name = MenuDialog.askText(
                title: "Rename Workbook",
                message: "Enter a new name for “\(workbook.name)”.",
                placeholder: "Workbook name",
                initial: workbook.name,
                confirm: "Rename"
            )
        else { return }
        workbooks.rename(workbook, to: name)
    }

    private func confirmDeleteActiveWorkbook() {
        guard let workbook = activeWorkbook else { return }
        let confirmed = MenuDialog.confirm(
            title: "Delete “\(workbook.name)”?",
            message: "The workbook and its list of files will be removed. The PDFs and notes themselves stay where they are on disk.",
            button: "Delete"
        )
        if confirmed {
            workbooks.delete(workbook)
        }
    }

    private func importPDFsIntoActiveWorkbook() {
        guard let workbook = activeWorkbook else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Add to Workbook"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        workbooks.importItems(from: panel.urls, to: workbook.id, folderID: nil)
    }

    private func confirmClearPageNotes(_ tab: PDFDocumentTab) {
        let confirmed = MenuDialog.confirm(
            title: "Clear all page notes?",
            message: "The AI notes for “\(tab.title)” will be deleted. This can’t be undone.",
            button: "Clear Notes"
        )
        if confirmed {
            tab.pageNotes.removeAll()
        }
    }

    private func runSelectionCommand(_ command: PDFDocumentTab.SelectionCommand) {
        guard let tab = focusedTab, let text = tab.selectedText else {
            NSSound.beep()
            return
        }
        store.handleSelectionCommand(
            command,
            text: text,
            pageIndex: tab.selectionPageIndex ?? tab.pageIndex,
            in: tab
        )
    }

    // MARK: - Menus

    @CommandsBuilder
    private var appCommands: some Commands {
        fileCommands
        editCommands
        viewCommands
        goCommands
        assistantCommands
        workbookCommands
        windowCommands
    }

    @CommandsBuilder
    private var fileCommands: some Commands {
        // "New" is useless here; keep "Open..." only.
        CommandGroup(replacing: .newItem) {
            Button("Open\u{2026}") {
                store.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(after: .saveItem) {
            Button("Save Note") {
                store.selectedNoteTab?.saveNow()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(store.selectedNoteTab == nil)

            Divider()

            Button("Close Tab") {
                store.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Reopen Closed Tab") {
                store.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!store.canReopenClosedTab)

            Divider()

            Button("Duplicate Tab") {
                if let tab = currentTab { store.duplicate(tab) }
            }
            .disabled(currentTab == nil)

            Button("Reload Tab") {
                if let tab = currentTab { store.reload(tab) }
            }
            .disabled(currentTab == nil)

            Button(pinTitle) {
                if let tab = currentTab { store.togglePin(tab) }
            }
            .disabled(currentTab == nil)

            Button("Close Other Tabs") {
                if let tab = currentTab { store.closeOtherTabs(keeping: tab) }
            }
            .disabled(currentTab.map { !store.canCloseOtherTabs(keeping: $0) } ?? true)

            Button("Close Tabs to the Right") {
                if let tab = currentTab { store.closeTabsToRight(of: tab) }
            }
            .disabled(currentTab.map { !store.canCloseTabsToRight(of: $0) } ?? true)

            Divider()

            Button("Reveal in Finder") {
                if let tab = currentTab {
                    NSWorkspace.shared.activateFileViewerSelecting([tab.url])
                }
            }
            .disabled(currentTab == nil)

            Divider()

            Menu("Open Flashcard Deck") {
                if agent.savedDecks.isEmpty {
                    Button("No saved decks") {}
                        .disabled(true)
                } else {
                    ForEach(agent.savedDecks) { deck in
                        Menu("\(deck.title) · \(deck.cardCount) cards") {
                            Button("Open") {
                                agent.openSavedDeck(deck)
                            }
                            Divider()
                            Menu("Add to Workbook") {
                                ForEach(workbooks.workbooks) { workbook in
                                    Button(workbook.name) {
                                        workbooks.add(
                                            workbooks.makeItem(kind: .deck, title: deck.title, url: deck.url),
                                            to: workbook.id)
                                    }
                                }
                            }
                            .disabled(workbooks.workbooks.isEmpty)
                            Button("Rename…") {
                                agent.promptRenameDeck(deck)
                            }
                            Button("Delete…") {
                                agent.confirmDeleteDeck(deck)
                            }
                        }
                    }
                }

                Divider()

                Button("Refresh List") {
                    agent.refreshSavedDecks()
                }
            }

            Menu("Open Summary") {
                if agent.savedSummaries.isEmpty {
                    Button("No saved summaries") {}
                        .disabled(true)
                } else {
                    ForEach(agent.savedSummaries) { summary in
                        Menu(summary.title) {
                            Button("Open") {
                                agent.openSavedSummary(summary)
                            }
                            Divider()
                            Menu("Add to Workbook") {
                                ForEach(workbooks.workbooks) { workbook in
                                    Button(workbook.name) {
                                        workbooks.add(
                                            workbooks.makeItem(kind: .summary, title: summary.title, url: summary.url),
                                            to: workbook.id)
                                    }
                                }
                            }
                            .disabled(workbooks.workbooks.isEmpty)
                            Button("Rename…") {
                                agent.promptRenameSummary(summary)
                            }
                            Button("Delete…") {
                                agent.confirmDeleteSummary(summary)
                            }
                        }
                    }
                }

                Divider()

                Button("Refresh List") {
                    agent.refreshSavedSummaries()
                }
            }

            Menu("Open Quiz") {
                if agent.savedQuizzes.isEmpty {
                    Button("No saved quizzes") {}
                        .disabled(true)
                } else {
                    ForEach(agent.savedQuizzes) { quiz in
                        Menu(quiz.title) {
                            Button("Open") {
                                agent.openSavedQuiz(quiz)
                            }
                            Divider()
                            Menu("Add to Workbook") {
                                ForEach(workbooks.workbooks) { workbook in
                                    Button(workbook.name) {
                                        workbooks.add(
                                            workbooks.makeItem(kind: .quiz, title: quiz.title, url: quiz.url),
                                            to: workbook.id)
                                    }
                                }
                            }
                            .disabled(workbooks.workbooks.isEmpty)
                            Button("Rename…") {
                                agent.promptRenameSavedQuiz(quiz)
                            }
                            Button("Delete…") {
                                agent.confirmDeleteSavedQuiz(quiz)
                            }
                        }
                    }
                }

                Divider()

                Button("Refresh List") {
                    agent.refreshSavedQuizzes()
                }
            }

            Divider()

            Button("New Note") {
                store.newNote()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Menu("Open Note") {
                let savedNotes = NotesStore.list()
                if savedNotes.isEmpty {
                    Button("No saved notes") {}
                        .disabled(true)
                } else {
                    ForEach(savedNotes, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            store.openNote(at: url)
                        }
                    }
                }
            }
        }

        CommandGroup(replacing: .printItem) {
            Button("Print\u{2026}") {
                focusedTab?.pdfView.print(with: NSPrintInfo.shared, autoRotate: true)
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(focusedTab == nil)
        }
    }

    @CommandsBuilder
    private var editCommands: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find\u{2026}") {
                store.beginFind()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(focusedTab == nil)

            Button("Find Next") {
                focusedTab?.nextMatch()
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(focusedTab == nil)

            Button("Find Previous") {
                focusedTab?.previousMatch()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(focusedTab == nil)

            Divider()

            Button("Highlight Selection") {
                focusedTab?.highlightSelection()
            }
            .keyboardShortcut("h", modifiers: [.command, .control])
            .disabled(focusedTab == nil)

            Menu("Highlight As") {
                ForEach(HighlightColor.allCases) { color in
                    Button(color.label) {
                        focusedTab?.highlightSelection(color: color)
                    }
                }
                Divider()
                Button("Underline") {
                    focusedTab?.highlightSelection(color: .blue, style: .underline)
                }
            }
            .disabled(focusedTab == nil)

            Menu("Selected Text") {
                Button("Ask Assistant About Selection") {
                    runSelectionCommand(.ask)
                }
                Button("Explain Selection") {
                    runSelectionCommand(.explain)
                }
                Button("Make Flashcards from Selection") {
                    runSelectionCommand(.flashcards)
                }
                Button("Add Selection to Note") {
                    runSelectionCommand(.addToNote)
                }
            }
            .disabled(focusedTab == nil)
        }
    }

    @CommandsBuilder
    private var viewCommands: some Commands {
        CommandGroup(after: .toolbar) {
            Button(store.showThumbnails ? "Hide Sidebar" : "Show Sidebar") {
                store.toggleThumbnails()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])

            Menu("Sidebar") {
                Picker("Sidebar", selection: sidebarModeBinding) {
                    Text("Pages").tag("pages")
                    Text("Contents").tag("contents")
                }
                .pickerStyle(.inline)
                .disabled(store.selectedTab?.outline.isEmpty ?? true)
            }

            Button(store.showAnnotations ? "Hide Page Notes" : "Show Page Notes") {
                store.toggleAnnotations()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(store.selectedTab == nil)

            Button(store.showLibrary ? "Hide Library" : "Show Library") {
                store.toggleLibrary()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])

            Divider()

            Button(store.isSplit || store.isSplitPickerVisible ? "Close Split View" : "Open in Split View\u{2026}") {
                if store.isSplit || store.isSplitPickerVisible {
                    store.collapseSplit()
                } else {
                    store.beginSplitPicker()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(store.selectedTab == nil || store.isGeneratedTabActive)

            Divider()

            Button("Zoom In") {
                focusedTab?.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(focusedTab == nil)

            Button("Zoom Out") {
                focusedTab?.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(focusedTab == nil)

            Button("Actual Size") {
                focusedTab?.actualSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(focusedTab == nil)

            Button("Fit to Width") {
                focusedTab?.fitToWidth()
            }
            .keyboardShortcut("9", modifiers: .command)
            .disabled(focusedTab == nil)

            Divider()

            Button("Lecture Portal") {
                store.openLecturePortal()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button(TodoWindowController.shared.isVisible ? "Hide Tasks" : "Show Tasks") {
                TodoWindowController.shared.toggle()
            }
        }
    }

    @CommandsBuilder
    private var goCommands: some Commands {
        CommandMenu("Go") {
            Button("Go to Page\u{2026}") {
                promptGoToPage()
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            .disabled(focusedTab == nil)

            Divider()

            Button("Previous Page") {
                if let tab = focusedTab, tab.pageIndex > 0 {
                    tab.go(toPageIndex: tab.pageIndex - 1)
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            .disabled(focusedTab == nil)

            Button("Next Page") {
                if let tab = focusedTab, tab.pageIndex < tab.pageCount - 1 {
                    tab.go(toPageIndex: tab.pageIndex + 1)
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            .disabled(focusedTab == nil)
        }
    }

    @CommandsBuilder
    private var assistantCommands: some Commands {
        CommandMenu("Assistant") {
            Button(store.showAgentPanel ? "Hide Assistant" : "Show Assistant") {
                store.toggleAgentPanel()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])

            Divider()

            Button("Ask About This Page") {
                store.showAssistant(scope: .currentPage)
            }
            .disabled(focusedTab == nil)

            Button("Ask About This Document") {
                store.showAssistant(scope: .wholeDocument)
            }
            .disabled(focusedTab == nil)

            Button("Ask About Workbook") {
                store.showAssistant(scope: .workbook)
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Divider()

            Button("Annotate This Page") {
                store.showAnnotations = true
                if let tab = focusedTab {
                    Task { await agent.annotateCurrentPage(tab) }
                }
            }
            .disabled(focusedTab == nil)

            Button("Annotate All Pages") {
                store.showAnnotations = true
                if let tab = focusedTab {
                    Task { await agent.annotatePages(tab) }
                }
            }
            .disabled(focusedTab == nil)

            Button("Clear Page Notes\u{2026}") {
                if let tab = focusedTab { confirmClearPageNotes(tab) }
            }
            .disabled(focusedTab?.pageNotes.isEmpty ?? true)

            Divider()

            Button(AIPromptWindowController.shared.isVisible ? "Hide AI Prompt" : "Show AI Prompt") {
                AIPromptWindowController.shared.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    @CommandsBuilder
    private var workbookCommands: some Commands {
        CommandMenu("Workbook") {
            Button("New Workbook\u{2026}") {
                promptNewWorkbook()
            }

            Divider()

            if workbooks.workbooks.isEmpty {
                Button("No workbooks") {}
                    .disabled(true)
            } else {
                ForEach(workbooks.workbooks) { workbook in
                    Toggle(
                        workbook.name,
                        isOn: Binding(
                            get: { workbooks.activeWorkbookID == workbook.id },
                            set: { _ in workbooks.selectWorkbook(workbook.id) }
                        )
                    )
                }
            }

            Divider()

            Button("Add PDFs to Workbook\u{2026}") {
                importPDFsIntoActiveWorkbook()
            }
            .disabled(activeWorkbook == nil)

            Button("Rename Workbook\u{2026}") {
                promptRenameActiveWorkbook()
            }
            .disabled(activeWorkbook == nil)

            Button("Delete Workbook\u{2026}") {
                confirmDeleteActiveWorkbook()
            }
            .disabled(activeWorkbook == nil)

            Divider()

            Button("Show Library") {
                store.showLibrary = true
            }
        }
    }

    @CommandsBuilder
    private var windowCommands: some Commands {
        CommandGroup(after: .windowArrangement) {
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

            Divider()

            ForEach(Array(store.tabs.prefix(9).enumerated()), id: \.offset) { entry in
                Button("\(entry.offset + 1). \(entry.element.title)") {
                    store.select(entry.element)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(entry.offset + 1)")), modifiers: .command)
            }
        }
    }
}

/// Small dialogs used by menu commands.
@MainActor
enum MenuDialog {
    /// Asks for a line of text. Returns nil if cancelled or left empty.
    static func askText(
        title: String,
        message: String,
        placeholder: String = "",
        initial: String = "",
        confirm: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Asks the user to confirm a destructive action.
    static func confirm(title: String, message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func info(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
