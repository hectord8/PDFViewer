import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClosedTab {
    let url: URL
    let pageIndex: Int
    let zoomMode: ZoomMode
    let scale: Double
}

private struct WorkbookSession: Codable {
    var paths: [String]
    var activePath: String?
}

@MainActor final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var tabs: [PDFDocumentTab] = []
    @Published var selectedTabID: UUID? {
        didSet {
            guard selectedTabID != oldValue else { return }
            // Bring saved notes back automatically when opening a PDF that has them.
            if let tab = selectedTab, !tab.pageNotes.isEmpty {
                showAnnotations = true
            }
        }
    }
    @Published var showThumbnails = true
    @Published var showAgentPanel = false
    @Published var showAnnotations = false
    @Published var showLibrary = false
    @Published var errorMessage: String?

    @Published var secondaryTabID: UUID?
    @Published var isSplitPickerVisible = false
    @Published var focusedPane: Pane = .primary
    @Published var splitFraction: Double = 0.5

    @Published var notesPanelWidth: Double = UserDefaults.standard.object(forKey: "notesPanelWidth") as? Double ?? 260
    @Published var agentPanelWidth: Double = UserDefaults.standard.object(forKey: "agentPanelWidth") as? Double ?? 360

    /// Persists the panel widths once a resize drag has finished (not per frame).
    func persistPanelWidths() {
        UserDefaults.standard.set(notesPanelWidth, forKey: "notesPanelWidth")
        UserDefaults.standard.set(agentPanelWidth, forKey: "agentPanelWidth")
    }

    @Published private(set) var pinnedTabIDs: Set<UUID> = []
    @Published private(set) var recentlyClosed: [ClosedTab] = []

    @Published private(set) var quizzes: [QuizTab] = []
    @Published var selectedQuizID: UUID?

    @Published private(set) var flashcards: [FlashcardTab] = []
    @Published var selectedFlashcardID: UUID?

    @Published private(set) var summaries: [SummaryTab] = []
    @Published var selectedSummaryID: UUID?

    @Published private(set) var notes: [NoteTab] = []
    @Published var selectedNoteID: UUID?
    @Published var secondaryNoteID: UUID?

    @Published private(set) var lectureTabs: [LectureTab] = []
    @Published var selectedLectureID: UUID?

    private let workbooks = WorkbookStore.shared

    @Published private var findBarTabID: UUID?

    private static let workbookSessionsKey = "workbookSessions"
    private var didRestoreSession = false
    private var saveWorkItem: DispatchWorkItem?

    var selectedTab: PDFDocumentTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var secondaryTab: PDFDocumentTab? {
        guard let secondaryTabID else { return nil }
        return tabs.first { $0.id == secondaryTabID }
    }

    var isSplit: Bool { secondaryTab != nil || secondaryNoteTab != nil }

    var selectedQuizTab: QuizTab? {
        guard let selectedQuizID else { return nil }
        return quizzes.first { $0.id == selectedQuizID }
    }

    var selectedFlashcardTab: FlashcardTab? {
        guard let selectedFlashcardID else { return nil }
        return flashcards.first { $0.id == selectedFlashcardID }
    }

    var selectedSummaryTab: SummaryTab? {
        guard let selectedSummaryID else { return nil }
        return summaries.first { $0.id == selectedSummaryID }
    }

    var selectedNoteTab: NoteTab? {
        guard let selectedNoteID else { return nil }
        return notes.first { $0.id == selectedNoteID }
    }

    var selectedLectureTab: LectureTab? {
        guard let selectedLectureID else { return nil }
        return lectureTabs.first { $0.id == selectedLectureID }
    }

    var secondaryNoteTab: NoteTab? {
        guard let secondaryNoteID else { return nil }
        return notes.first { $0.id == secondaryNoteID }
    }

    var isQuizActive: Bool { selectedQuizTab != nil }
    var isFlashcardActive: Bool { selectedFlashcardTab != nil }
    var isSummaryActive: Bool { selectedSummaryTab != nil }
    var isNoteActive: Bool { selectedNoteTab != nil && secondaryNoteTab == nil }
    var isLectureActive: Bool { selectedLectureTab != nil }
    var isGeneratedTabActive: Bool {
        isQuizActive || isFlashcardActive || isSummaryActive || isNoteActive || isLectureActive
    }

    var activeTab: PDFDocumentTab? {
        if isSplit, focusedPane == .secondary, let secondaryTab { return secondaryTab }
        return selectedTab
    }

    func isFindBarVisible(for tab: PDFDocumentTab) -> Bool {
        findBarTabID == tab.id
    }

    func isPinned(_ tab: PDFDocumentTab) -> Bool {
        pinnedTabIDs.contains(tab.id)
    }

    private var pinnedCount: Int {
        tabs.filter { pinnedTabIDs.contains($0.id) }.count
    }

    // MARK: - Opening

    func presentOpenPanel(after anchor: PDFDocumentTab? = nil) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose one or more PDF files"

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls, after: anchor)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Entry point for the open panel, Finder, "Open With" and Dock drops.
    func open(urls: [URL], after anchor: PDFDocumentTab? = nil) {
        guard !urls.isEmpty else { return }

        var created: [PDFDocumentTab] = []
        var alreadyOpen: PDFDocumentTab?

        for url in urls {
            let standardized = url.resolvingSymlinksInPath().standardizedFileURL

            if let existing = tabs.first(where: {
                $0.url.resolvingSymlinksInPath().standardizedFileURL == standardized
            }) {
                alreadyOpen = alreadyOpen ?? existing
                continue
            }

            guard let tab = PDFDocumentTab(url: url) else {
                errorMessage =
                    "“\(url.lastPathComponent)” could not be opened. "
                    + "It may not be a valid PDF, may be damaged, or may use an unsupported encryption."
                continue
            }

            configure(tab)
            tabs.append(tab)
            created.append(tab)
        }

        if let anchor, !created.isEmpty, tabs.contains(where: { $0.id == anchor.id }) {
            let createdIDs = Set(created.map(\.id))
            tabs.removeAll { createdIDs.contains($0.id) }
            let anchorIndex = tabs.firstIndex(where: { $0.id == anchor.id }) ?? (tabs.count - 1)
            let insertAt = min(max(anchorIndex + 1, pinnedCount), tabs.count)
            tabs.insert(contentsOf: created, at: insertAt)
        }

        if let first = created.first {
            selectedTabID = first.id
            focusedPane = .primary
        } else if let alreadyOpen {
            select(alreadyOpen)
        }
        scheduleSessionSave()
    }

    private func configure(_ tab: PDFDocumentTab) {
        tab.onDirty = { [weak self] in self?.scheduleSessionSave() }
        tab.onFocus = { [weak self] in self?.focusPane(containing: tab) }
        tab.onSelectionCommand = { [weak self, weak tab] command, text, pageIndex in
            guard let self, let tab else { return }
            self.handleSelectionCommand(command, text: text, pageIndex: pageIndex, in: tab)
        }
    }

    // MARK: - Selection actions

    /// Right-click actions on text selected in a PDF.
    func handleSelectionCommand(
        _ command: PDFDocumentTab.SelectionCommand,
        text: String,
        pageIndex: Int,
        in tab: PDFDocumentTab
    ) {
        let agent = AgentChatModel.shared

        switch command {
        case .ask:
            agent.attachSelection(text, documentTitle: tab.title, pageIndex: pageIndex)
            showAssistant()
            agent.focusInputRequest += 1

        case .explain:
            agent.attachSelection(text, documentTitle: tab.title, pageIndex: pageIndex)
            showAssistant()
            let pageContext = AgentChatModel.context(for: tab, scope: .currentPage)
            Task {
                await agent.ask(
                    "Explain the selected passage in plain language, using the surrounding page for context.",
                    context: pageContext
                )
            }

        case .flashcards:
            agent.attachSelection(text, documentTitle: tab.title, pageIndex: pageIndex)
            showAssistant()
            Task { await agent.ask("Make flashcards from the selected passage.", context: nil) }

        case .addToNote:
            addSelectionToNote(text, pageIndex: pageIndex, from: tab)
        }
    }

    /// Appends a quote (with its source) to the note beside the PDF, opening
    /// a note for this document in split view if there isn't one yet.
    private func addSelectionToNote(_ text: String, pageIndex: Int, from tab: PDFDocumentTab) {
        let title = "Notes – \(tab.title)"
        let note: NoteTab
        if let open = secondaryNoteTab {
            note = open
        } else if let existing = notes.first(where: { $0.title == title }) {
            note = existing
        } else {
            note = NoteTab(title: title, text: NotesStore.emptyText(), fileURL: nil)
            note.onFirstSave = { [weak self] note in self?.addNoteToActiveWorkbook(note) }
            notes.append(note)
        }

        let combined = NSMutableAttributedString(attributedString: note.text)
        if combined.length > 0 {
            combined.append(NSAttributedString(string: "\n\n"))
        }
        combined.append(
            NSAttributedString(
                string: "“\(text)”\n",
                attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.textColor]
            )
        )
        combined.append(
            NSAttributedString(
                string: "— \(tab.title), p. \(pageIndex + 1)",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            )
        )
        note.text = combined
        note.markChanged()

        if secondaryNoteID != note.id {
            selectedTabID = tab.id
            splitNoteWithPDF(note)
        }
    }

    /// Files dropped onto the window. Each provider resolves asynchronously, so we
    /// wait for all of them and then open in the order they were dropped.
    func open(providers: [NSItemProvider]) -> Bool {
        let pdfProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !pdfProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var resolved = [URL?](repeating: nil, count: pdfProviders.count)

        for (index, provider) in pdfProviders.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { object, _ in
                defer { group.leave() }
                guard let url = object else { return }
                lock.lock()
                resolved[index] = url
                lock.unlock()
            }
        }

        group.notify(queue: .main) { [weak self] in
            let urls = resolved.compactMap { $0 }
            guard !urls.isEmpty else { return }
            self?.open(urls: urls)
        }
        return true
    }

    // MARK: - Tabs

    func select(_ tab: PDFDocumentTab) {
        selectedQuizID = nil
        selectedFlashcardID = nil
        selectedSummaryID = nil
        selectedNoteID = nil
        selectedLectureID = nil
        if isSplit {
            if tab.id == selectedTabID {
                focusedPane = .primary
                scheduleSessionSave()
                return
            }
            if tab.id == secondaryTabID {
                focusedPane = .secondary
                scheduleSessionSave()
                return
            }
            secondaryTabID = nil
            focusedPane = .primary
        }

        selectedTabID = tab.id
        scheduleSessionSave()
    }

    func selectAdjacentTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = activeTab?.id ?? selectedTabID,
            let index = tabs.firstIndex(where: { $0.id == current })
        else {
            selectedTabID = tabs.first?.id
            scheduleSessionSave()
            return
        }

        let count = tabs.count
        let next = ((index + offset) % count + count) % count
        select(tabs[next])
    }

    // MARK: - Quizzes

    func openQuiz(_ tab: QuizTab) {
        quizzes.append(tab)
        collapseSplitForGeneratedTab()
        selectedFlashcardID = nil
        selectedSummaryID = nil
        selectedLectureID = nil
        selectedQuizID = tab.id
    }

    func selectQuiz(_ tab: QuizTab) {
        guard quizzes.contains(where: { $0.id == tab.id }) else { return }
        collapseSplitForGeneratedTab()
        selectedFlashcardID = nil
        selectedSummaryID = nil
        selectedLectureID = nil
        selectedQuizID = tab.id
    }

    func closeQuiz(_ tab: QuizTab) {
        guard let index = quizzes.firstIndex(where: { $0.id == tab.id }) else { return }
        quizzes.remove(at: index)
        if selectedQuizID == tab.id {
            selectedQuizID = nil
        }
    }

    func updateQuiz(filePath: String, title: String, newURL: URL) {
        guard let quiz = quizzes.first(where: { $0.fileURL?.path == filePath }) else { return }
        quiz.title = title
        quiz.fileURL = newURL
    }

    func closeQuizzes(filePath: String) {
        let matches = quizzes.filter { $0.fileURL?.path == filePath }
        matches.forEach { closeQuiz($0) }
    }

    // MARK: - Flashcards

    func openFlashcard(_ tab: FlashcardTab) {
        flashcards.append(tab)
        collapseSplitForGeneratedTab()
        selectedQuizID = nil
        selectedSummaryID = nil
        selectedLectureID = nil
        selectedFlashcardID = tab.id
    }

    func selectFlashcard(_ tab: FlashcardTab) {
        guard flashcards.contains(where: { $0.id == tab.id }) else { return }
        collapseSplitForGeneratedTab()
        selectedQuizID = nil
        selectedSummaryID = nil
        selectedLectureID = nil
        selectedFlashcardID = tab.id
    }

    func closeFlashcard(_ tab: FlashcardTab) {
        guard let index = flashcards.firstIndex(where: { $0.id == tab.id }) else { return }
        flashcards.remove(at: index)
        if selectedFlashcardID == tab.id {
            selectedFlashcardID = nil
        }
    }

    func updateFlashcardTitle(deckPath: String, title: String) {
        flashcards.first { $0.deckURL?.path == deckPath }?.title = title
    }

    func closeFlashcards(deckPath: String) {
        let matches = flashcards.filter { $0.deckURL?.path == deckPath }
        matches.forEach { closeFlashcard($0) }
    }

    // MARK: - Summaries

    func openSummary(_ tab: SummaryTab) {
        summaries.append(tab)
        collapseSplitForGeneratedTab()
        selectedQuizID = nil
        selectedFlashcardID = nil
        selectedLectureID = nil
        selectedSummaryID = tab.id
    }

    func selectSummary(_ tab: SummaryTab) {
        guard summaries.contains(where: { $0.id == tab.id }) else { return }
        collapseSplitForGeneratedTab()
        selectedQuizID = nil
        selectedFlashcardID = nil
        selectedLectureID = nil
        selectedSummaryID = tab.id
    }

    func closeSummary(_ tab: SummaryTab) {
        guard let index = summaries.firstIndex(where: { $0.id == tab.id }) else { return }
        summaries.remove(at: index)
        if selectedSummaryID == tab.id {
            selectedSummaryID = nil
        }
    }

    func updateSummaryTitle(filePath: String, title: String) {
        summaries.first { $0.fileURL?.path == filePath }?.title = title
    }

    func closeSummaries(filePath: String) {
        let matches = summaries.filter { $0.fileURL?.path == filePath }
        matches.forEach { closeSummary($0) }
    }

    // MARK: - Notes

    @discardableResult
    func newNote() -> NoteTab {
        let note = NoteTab(title: "Untitled Note", text: NotesStore.emptyText(), fileURL: nil)
        note.onFirstSave = { [weak self] note in self?.addNoteToActiveWorkbook(note) }
        notes.append(note)
        selectNote(note)
        return note
    }

    /// Creates a note from generated text (e.g. a lecture transcript), saves it,
    /// and optionally files it into the active workbook through the normal
    /// first-save path.
    @discardableResult
    func createNote(
        title: String,
        text: NSAttributedString,
        addToActiveWorkbook: Bool = true
    ) -> NoteTab {
        let note = NoteTab(title: title, text: text, fileURL: nil)
        if addToActiveWorkbook {
            note.onFirstSave = { [weak self] note in self?.addNoteToActiveWorkbook(note) }
        }
        notes.append(note)
        selectNote(note)
        note.saveNow()
        return note
    }

    /// Adds a freshly-saved note into the active workbook (under a "Notes"
    /// folder), the same way generated flashcards/summaries are filed.
    private func addNoteToActiveWorkbook(_ note: NoteTab) {
        guard let url = note.fileURL,
            let workbookID = workbooks.activeWorkbookID,
            let workbook = workbooks.workbooks.first(where: { $0.id == workbookID })
        else {
            return
        }

        let folderID: UUID?
        if let existing = workbook.folders.first(where: { $0.name.caseInsensitiveCompare("Notes") == .orderedSame }) {
            folderID = existing.id
        } else {
            folderID = workbooks.addFolder(named: "Notes", to: workbookID)
        }

        workbooks.add(workbooks.makeItem(kind: .note, title: note.title, url: url), to: workbookID, folderID: folderID)
    }

    func openNote(at url: URL) {
        if let existing = notes.first(where: { $0.fileURL?.path == url.path }) {
            selectNote(existing)
            return
        }
        guard let loaded = NotesStore.load(url) else {
            errorMessage = "“\(url.lastPathComponent)” could not be opened."
            return
        }
        let note = NoteTab(title: loaded.title, text: loaded.text, fileURL: url)
        notes.append(note)
        selectNote(note)
    }

    func selectNote(_ note: NoteTab) {
        if secondaryTabID != nil {
            secondaryTabID = nil
            focusedPane = .primary
        }
        isSplitPickerVisible = false
        secondaryNoteID = nil
        selectedQuizID = nil
        selectedFlashcardID = nil
        selectedSummaryID = nil
        selectedLectureID = nil
        selectedNoteID = note.id
    }

    func closeNote(_ note: NoteTab) {
        note.saveNow()
        notes.removeAll { $0.id == note.id }
        if selectedNoteID == note.id {
            selectedNoteID = nil
        }
        if secondaryNoteID == note.id {
            secondaryNoteID = nil
        }
    }

    /// Shows this note beside the currently-selected PDF.
    func splitNoteWithPDF(_ note: NoteTab) {
        guard let pdf = selectedTab else { return }
        isSplitPickerVisible = false
        secondaryTabID = nil
        selectedTabID = pdf.id
        selectedNoteID = nil
        secondaryNoteID = note.id
        focusedPane = .secondary
    }

    // MARK: - Lecture Portal

    func openLecturePortal() {
        if lectureTabs.isEmpty {
            lectureTabs = [LectureTab()]
        }
        collapseSplitForGeneratedTab()
        secondaryNoteID = nil
        selectedQuizID = nil
        selectedFlashcardID = nil
        selectedSummaryID = nil
        selectedNoteID = nil
        selectedLectureID = lectureTabs[0].id
    }

    func selectLectureTab(_ tab: LectureTab) {
        guard lectureTabs.contains(where: { $0.id == tab.id }) else { return }
        collapseSplitForGeneratedTab()
        secondaryNoteID = nil
        selectedQuizID = nil
        selectedFlashcardID = nil
        selectedSummaryID = nil
        selectedNoteID = nil
        selectedLectureID = tab.id
    }

    func closeLectureTab(_ tab: LectureTab) {
        lectureTabs.removeAll { $0.id == tab.id }
        if selectedLectureID == tab.id {
            selectedLectureID = lectureTabs.first?.id
        }
    }

    private func collapseSplitForGeneratedTab() {
        isSplitPickerVisible = false
        if isSplit {
            secondaryTabID = nil
            focusedPane = .primary
        }
    }

    // MARK: - Split view

    func split(with tab: PDFDocumentTab) {
        select(tab)
        beginSplitPicker()
    }

    func beginSplitPicker() {
        guard selectedTab != nil, !isGeneratedTabActive else { return }
        secondaryTabID = nil
        secondaryNoteID = nil
        isSplitPickerVisible = true
        focusedPane = .primary
        scheduleSessionSave()
    }

    func cancelSplitPicker() {
        guard isSplitPickerVisible else { return }
        isSplitPickerVisible = false
        focusedPane = .primary
    }

    func chooseSecondaryTab(_ tab: PDFDocumentTab) {
        guard tab.id != selectedTabID else { return }
        secondaryTabID = tab.id
        secondaryNoteID = nil
        isSplitPickerVisible = false
        focusedPane = .secondary
        scheduleSessionSave()
    }

    func chooseSecondaryNote(_ note: NoteTab) {
        guard selectedTab != nil else { return }
        selectedNoteID = nil
        secondaryNoteID = note.id
        secondaryTabID = nil
        isSplitPickerVisible = false
        focusedPane = .secondary
        scheduleSessionSave()
    }

    func openRecentAsSecondary(_ recent: ClosedTab) {
        if let existing = tabs.first(where: { $0.url.path == recent.url.path }) {
            chooseSecondaryTab(existing)
        } else if let tab = PDFDocumentTab(url: recent.url) {
            configure(tab)
            tab.restore(pageIndex: recent.pageIndex, zoomMode: recent.zoomMode, scale: recent.scale)
            tabs.append(tab)
            chooseSecondaryTab(tab)
        } else {
            errorMessage = "“\(recent.url.lastPathComponent)” could not be reopened."
        }
        recentlyClosed.removeAll { $0.url.path == recent.url.path }
    }

    func collapseSplit() {
        guard secondaryTabID != nil || secondaryNoteID != nil || isSplitPickerVisible else {
            return
        }
        secondaryTabID = nil
        secondaryNoteID = nil
        isSplitPickerVisible = false
        focusedPane = .primary
        scheduleSessionSave()
    }

    func focusPane(containing tab: PDFDocumentTab) {
        guard isSplit else { return }
        focusedPane = tab.id == secondaryTabID ? .secondary : .primary
    }

    func commitSplitLayout() {
        scheduleSessionSave()
    }

    func closeTab(_ tab: PDFDocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        let wasFocused = selectedTabID == tab.id
        let wasSecondary = secondaryTabID == tab.id

        rememberClosed(tab)
        tabs.remove(at: index)
        pinnedTabIDs.remove(tab.id)
        tab.clearSearch()

        if findBarTabID == tab.id {
            findBarTabID = nil
        }

        if wasSecondary {
            secondaryTabID = nil
            focusedPane = .primary
        }

        if wasFocused {
            if isSplit, let surviving = secondaryTab {
                secondaryTabID = nil
                focusedPane = .primary
                selectedTabID = surviving.id
            } else {
                selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
            }
        } else if selectedTabID == nil {
            selectedTabID = tabs.first?.id
        }
        scheduleSessionSave()
    }

    func closeSelectedTab() {
        guard let tab = activeTab else { return }
        closeTab(tab)
    }

    // MARK: - Tab management

    func pin(_ tab: PDFDocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        pinnedTabIDs.insert(tab.id)
        let moved = tabs.remove(at: index)
        tabs.insert(moved, at: min(pinnedCount, tabs.count))
        scheduleSessionSave()
    }

    func unpin(_ tab: PDFDocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        pinnedTabIDs.remove(tab.id)
        let moved = tabs.remove(at: index)
        tabs.insert(moved, at: min(pinnedCount, tabs.count))
        scheduleSessionSave()
    }

    func togglePin(_ tab: PDFDocumentTab) {
        isPinned(tab) ? unpin(tab) : pin(tab)
    }

    func duplicate(_ tab: PDFDocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        guard let copy = PDFDocumentTab(url: tab.url) else { return }

        configure(copy)
        copy.restore(
            pageIndex: tab.pageIndex,
            zoomMode: tab.zoomMode,
            scale: Double(tab.pdfView.scaleFactor)
        )
        let insertAt = pinnedTabIDs.contains(tab.id) ? pinnedCount : index + 1
        tabs.insert(copy, at: min(insertAt, tabs.count))
        selectedTabID = copy.id
        focusedPane = .primary
        scheduleSessionSave()
    }

    func reload(_ tab: PDFDocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        guard let fresh = PDFDocumentTab(url: tab.url) else { return }

        let wasPinned = pinnedTabIDs.contains(tab.id)
        configure(fresh)
        fresh.restore(
            pageIndex: tab.pageIndex,
            zoomMode: tab.zoomMode,
            scale: Double(tab.pdfView.scaleFactor)
        )

        tabs[index] = fresh
        tab.clearSearch()

        if wasPinned {
            pinnedTabIDs.remove(tab.id)
            pinnedTabIDs.insert(fresh.id)
        }
        if selectedTabID == tab.id {
            selectedTabID = fresh.id
        }
        if secondaryTabID == tab.id {
            secondaryTabID = fresh.id
        }
        if findBarTabID == tab.id {
            findBarTabID = fresh.id
        }
        scheduleSessionSave()
    }

    func canCloseOtherTabs(keeping tab: PDFDocumentTab) -> Bool {
        let closable = tabs.filter { $0.id != tab.id && !pinnedTabIDs.contains($0.id) }
        return !closable.isEmpty
    }

    func closeOtherTabs(keeping tab: PDFDocumentTab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        let removed = tabs.filter { $0.id != tab.id && !pinnedTabIDs.contains($0.id) }
        guard !removed.isEmpty else { return }

        let removedIDs = Set(removed.map(\.id))
        removed.forEach { rememberClosed($0) }
        tabs.removeAll { removedIDs.contains($0.id) }
        removed.forEach { $0.clearSearch() }
        pinnedTabIDs.subtract(removedIDs)

        selectedTabID = tab.id
        focusedPane = .primary
        if let secondary = secondaryTabID, removedIDs.contains(secondary) {
            secondaryTabID = nil
        }
        if let find = findBarTabID, removedIDs.contains(find) {
            findBarTabID = nil
        }
        scheduleSessionSave()
    }

    func canCloseTabsToRight(of tab: PDFDocumentTab) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return false }
        return index < tabs.count - 1
    }

    func closeTabsToRight(of tab: PDFDocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let removed = Array(tabs[(index + 1)...])
        guard !removed.isEmpty else { return }

        let removedIDs = Set(removed.map(\.id))
        removed.forEach { rememberClosed($0) }
        tabs.removeLast(removed.count)
        removed.forEach { $0.clearSearch() }
        pinnedTabIDs.subtract(removedIDs)

        if let selected = selectedTabID, removedIDs.contains(selected) {
            selectedTabID = tab.id
        }
        if let secondary = secondaryTabID, removedIDs.contains(secondary) {
            secondaryTabID = nil
            focusedPane = .primary
        }
        if let find = findBarTabID, removedIDs.contains(find) {
            findBarTabID = nil
        }
        scheduleSessionSave()
    }

    var canReopenClosedTab: Bool {
        !recentlyClosed.isEmpty
    }

    func reopenClosedTab() {
        guard let state = recentlyClosed.popLast() else { return }

        if let existing = tabs.first(where: { $0.url.path == state.url.path }) {
            select(existing)
            return
        }

        guard let tab = PDFDocumentTab(url: state.url) else { return }
        configure(tab)
        tab.restore(pageIndex: state.pageIndex, zoomMode: state.zoomMode, scale: state.scale)
        tabs.append(tab)
        selectedTabID = tab.id
        focusedPane = .primary
        scheduleSessionSave()
    }

    private func rememberClosed(_ tab: PDFDocumentTab) {
        recentlyClosed.append(
            ClosedTab(
                url: tab.url,
                pageIndex: tab.pageIndex,
                zoomMode: tab.zoomMode,
                scale: Double(tab.pdfView.scaleFactor)
            )
        )
        if recentlyClosed.count > 15 {
            recentlyClosed.removeFirst(recentlyClosed.count - 15)
        }
    }

    // MARK: - View toggles and zoom

    func toggleThumbnails() {
        showThumbnails.toggle()
        scheduleSessionSave()
    }

    func toggleAgentPanel() {
        if showAgentPanel {
            showAgentPanel = false
        } else {
            showAssistant()
        }
    }

    /// Opens the assistant panel, optionally switching what it answers about.
    /// With no document open, a document-only scope falls back to the workbook.
    func showAssistant(scope: AgentChatModel.ContextScope? = nil) {
        let agent = AgentChatModel.shared
        if let scope {
            agent.contextScope = scope
        } else if activeTab == nil, agent.contextScope == .currentPage || agent.contextScope == .wholeDocument {
            agent.contextScope = .workbook
        }
        showAgentPanel = true
    }

    func toggleAnnotations() {
        showAnnotations.toggle()
    }

    func toggleLibrary() {
        showLibrary.toggle()
    }

    func zoomIn() {
        activeTab?.zoomIn()
    }

    func zoomOut() {
        activeTab?.zoomOut()
    }

    func actualSize() {
        activeTab?.actualSize()
    }

    func fitToWidth() {
        activeTab?.fitToWidth()
    }

    // MARK: - Find

    func beginFind() {
        guard let tab = activeTab else { return }
        findBarTabID = tab.id
        tab.searchText = ""
        tab.performSearch()
    }

    func endFind() {
        if let findBarTabID, let tab = tabs.first(where: { $0.id == findBarTabID }) {
            tab.clearSearch()
        }
        findBarTabID = nil
    }

    // MARK: - Session persistence

    // MARK: - Workbook sessions

    /// Called when the selected workbook changes: remember the old workbook's
    /// open files, then reopen/select the new workbook's files.
    func workbookChanged(from oldID: UUID?, to newID: UUID?) {
        if let oldID {
            saveWorkbookSession(oldID)
        }
        if let newID, newID != oldID {
            activateWorkbook(newID)
        }
    }

    /// Restores the files that were open the last time this workbook was active.
    /// On first entry, opens the workbook's PDFs.
    func activateWorkbook(_ id: UUID?) {
        guard let id, let workbook = workbooks.workbooks.first(where: { $0.id == id }) else {
            return
        }

        let sessions = loadWorkbookSessions()
        if let session = sessions[id.uuidString], !session.paths.isEmpty {
            for path in session.paths where !isOpen(path: path) {
                if let item = allItems(in: workbook).first(where: { $0.path == path }) {
                    openWorkbookItem(item)
                }
            }
            if let active = session.activePath, isOpen(path: active) {
                selectPath(active)
            } else if let first = session.paths.first(where: { isOpen(path: $0) }) {
                selectPath(first)
            }
        } else {
            let pdfs = allItems(in: workbook).filter { $0.kind == .pdf }
            let urls = pdfs.compactMap { workbooks.url(for: $0) }
            if !urls.isEmpty {
                open(urls: urls)
            }
        }
    }

    private func saveWorkbookSession(_ id: UUID) {
        guard let workbook = workbooks.workbooks.first(where: { $0.id == id }) else { return }

        var sessions = loadWorkbookSessions()
        sessions[id.uuidString] = WorkbookSession(
            paths: openPaths(in: workbook),
            activePath: activeFilePath.flatMap { workbook.containsPath($0) ? $0 : nil }
        )
        saveWorkbookSessions(sessions)
    }

    private func openPaths(in workbook: Workbook) -> [String] {
        let paths =
            tabs.map(\.url.path)
            + notes.compactMap(\.fileURL?.path)
            + summaries.compactMap(\.fileURL?.path)
            + flashcards.compactMap(\.deckURL?.path)
            + quizzes.compactMap(\.fileURL?.path)
        return paths.filter { workbook.containsPath($0) }
    }

    private var activeFilePath: String? {
        if let note = selectedNoteTab { return note.fileURL?.path }
        if let summary = selectedSummaryTab { return summary.fileURL?.path }
        if let deck = selectedFlashcardTab { return deck.deckURL?.path }
        if let quiz = selectedQuizTab { return quiz.fileURL?.path }
        return activeTab?.url.path
    }

    private func isOpen(path: String) -> Bool {
        tabs.contains { $0.url.path == path }
            || notes.contains { $0.fileURL?.path == path }
            || summaries.contains { $0.fileURL?.path == path }
            || flashcards.contains { $0.deckURL?.path == path }
            || quizzes.contains { $0.fileURL?.path == path }
    }

    private func selectPath(_ path: String) {
        if let tab = tabs.first(where: { $0.url.path == path }) {
            select(tab)
        } else if let note = notes.first(where: { $0.fileURL?.path == path }) {
            selectNote(note)
        } else if let summary = summaries.first(where: { $0.fileURL?.path == path }) {
            selectSummary(summary)
        } else if let deck = flashcards.first(where: { $0.deckURL?.path == path }) {
            selectFlashcard(deck)
        } else if let quiz = quizzes.first(where: { $0.fileURL?.path == path }) {
            selectQuiz(quiz)
        }
    }

    private func allItems(in workbook: Workbook) -> [WorkbookItem] {
        var items = workbook.items
        func walk(_ folders: [WorkbookFolder]) {
            for folder in folders {
                items.append(contentsOf: folder.items)
                walk(folder.folders)
            }
        }
        walk(workbook.folders)
        return items
    }

    private func openWorkbookItem(_ item: WorkbookItem) {
        guard let url = workbooks.url(for: item) else { return }

        switch item.kind {
        case .pdf:
            open(urls: [url])
        case .note:
            openNote(at: url)
        case .summary:
            let title = item.title
            Task { @MainActor in
                AgentChatModel.shared.openSavedSummary(
                    AgentChatModel.SavedSummary(
                        id: url.path,
                        title: title,
                        url: url,
                        modified: .distantPast
                    )
                )
            }
        case .deck:
            let title = item.title
            Task { @MainActor in
                AgentChatModel.shared.openSavedDeck(
                    AgentChatModel.SavedDeck(
                        id: url.path,
                        title: title,
                        url: url,
                        cardCount: 0,
                        modified: .distantPast
                    )
                )
            }
        case .quiz:
            Task { @MainActor in
                AgentChatModel.shared.openSavedQuiz(at: url)
            }
        case .file:
            break
        }
    }

    private func loadWorkbookSessions() -> [String: WorkbookSession] {
        guard let data = UserDefaults.standard.data(forKey: Self.workbookSessionsKey),
            let decoded = try? JSONDecoder().decode([String: WorkbookSession].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    private func saveWorkbookSessions(_ sessions: [String: WorkbookSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: Self.workbookSessionsKey)
    }

    func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true

        guard let session = SessionStore.load() else { return }

        showThumbnails = session.showThumbnails
        if let fraction = session.splitFraction, fraction > 0.05, fraction < 0.95 {
            splitFraction = fraction
        }

        var restored: [PDFDocumentTab] = []
        for state in session.tabs {
            guard let url = SessionStore.resolve(state) else { continue }
            guard let tab = PDFDocumentTab(url: url) else { continue }
            configure(tab)
            tab.restore(
                pageIndex: state.pageIndex,
                zoomMode: state.zoomMode,
                scale: state.scale
            )
            restored.append(tab)
        }

        tabs = restored

        if let pinnedPaths = session.pinnedPaths, !pinnedPaths.isEmpty {
            pinnedTabIDs = Set(restored.filter { pinnedPaths.contains($0.url.path) }.map(\.id))
            if !pinnedTabIDs.isEmpty {
                let pinned = restored.filter { pinnedTabIDs.contains($0.id) }
                let rest = restored.filter { !pinnedTabIDs.contains($0.id) }
                tabs = pinned + rest
            }
        }

        if let selectedPath = session.selectedPath,
            let match = restored.first(where: { $0.url.path == selectedPath })
        {
            selectedTabID = match.id
        } else {
            selectedTabID = restored.first?.id
        }

        if let secondaryPath = session.secondaryPath {
            let resolved = SessionStore.resolve(path: secondaryPath, bookmark: session.secondaryBookmark)
            let target = resolved?.path ?? secondaryPath
            if let match = restored.first(where: { $0.url.path == target && $0.id != selectedTabID }) {
                secondaryTabID = match.id
            }
        }

        focusedPane = secondaryTabID == nil ? .primary : (session.focusedPane ?? .primary)
    }

    func saveSessionNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        writeSession()
    }

    private func scheduleSessionSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeSession()
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private func writeSession() {
        if let active = workbooks.activeWorkbookID {
            saveWorkbookSession(active)
        }

        let session = Session(
            showThumbnails: showThumbnails,
            selectedPath: selectedTab?.url.path,
            secondaryPath: secondaryTab?.url.path,
            secondaryBookmark: secondaryTab.flatMap { SessionStore.makeBookmark(for: $0.url) },
            focusedPane: focusedPane,
            splitFraction: splitFraction,
            pinnedPaths: tabs.filter { pinnedTabIDs.contains($0.id) }.map(\.url.path),
            tabs: tabs.map { tab in
                TabState(
                    path: tab.url.path,
                    bookmark: SessionStore.makeBookmark(for: tab.url),
                    pageIndex: tab.pageIndex,
                    zoomMode: tab.zoomMode,
                    scale: Double(tab.pdfView.scaleFactor)
                )
            }
        )
        SessionStore.save(session)
    }
}
