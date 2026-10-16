import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var tabs: [PDFDocumentTab] = []
    @Published var selectedTabID: UUID?
    @Published var showThumbnails = true
    @Published var errorMessage: String?

    @Published private var findBarTabID: UUID?

    private var didRestoreSession = false
    private var saveWorkItem: DispatchWorkItem?

    var selectedTab: PDFDocumentTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var isFindBarVisible: Bool {
        guard let findBarTabID else { return false }
        return findBarTabID == selectedTab?.id
    }

    // MARK: - Opening

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose one or more PDF files"

        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            self?.open(urls: panel.urls)
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Entry point for the open panel, Finder, "Open With" and Dock drops.
    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }

        var newlyOpened: PDFDocumentTab?
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
                errorMessage = "“\(url.lastPathComponent)” could not be opened. "
                    + "It may not be a valid PDF, may be damaged, or may use an unsupported encryption."
                continue
            }

            tab.onDirty = { [weak self] in self?.scheduleSessionSave() }
            tabs.append(tab)
            newlyOpened = newlyOpened ?? tab
        }

        if let target = newlyOpened ?? alreadyOpen {
            selectedTabID = target.id
        }
        scheduleSessionSave()
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
        selectedTabID = tab.id
        scheduleSessionSave()
    }

    func selectAdjacentTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        guard let current = selectedTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else {
            selectedTabID = tabs.first?.id
            scheduleSessionSave()
            return
        }

        let count = tabs.count
        let next = ((index + offset) % count + count) % count
        selectedTabID = tabs[next].id
        scheduleSessionSave()
    }

    func closeTab(_ tab: PDFDocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }

        tabs.remove(at: index)
        tab.clearSearch()

        if selectedTabID == tab.id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        scheduleSessionSave()
    }

    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(tab)
    }

    // MARK: - View toggles and zoom

    func toggleThumbnails() {
        showThumbnails.toggle()
        scheduleSessionSave()
    }

    func zoomIn() {
        selectedTab?.zoomIn()
    }

    func zoomOut() {
        selectedTab?.zoomOut()
    }

    func actualSize() {
        selectedTab?.actualSize()
    }

    func fitToWidth() {
        selectedTab?.fitToWidth()
    }

    // MARK: - Find

    func beginFind() {
        guard let tab = selectedTab else { return }
        findBarTabID = tab.id
        tab.searchText = ""
        tab.performSearch()
    }

    func endFind() {
        selectedTab?.clearSearch()
        findBarTabID = nil
    }

    // MARK: - Session persistence

    func restoreSessionIfNeeded() {
        guard !didRestoreSession else { return }
        didRestoreSession = true

        guard let session = SessionStore.load() else { return }

        showThumbnails = session.showThumbnails

        var restored: [PDFDocumentTab] = []
        for state in session.tabs {
            guard let url = SessionStore.resolve(state) else { continue }
            guard let tab = PDFDocumentTab(url: url) else { continue }
            tab.onDirty = { [weak self] in self?.scheduleSessionSave() }
            tab.restore(
                pageIndex: state.pageIndex,
                zoomMode: state.zoomMode,
                scale: state.scale
            )
            restored.append(tab)
        }

        tabs = restored

        if let selectedPath = session.selectedPath,
           let match = restored.first(where: { $0.url.path == selectedPath }) {
            selectedTabID = match.id
        } else {
            selectedTabID = restored.first?.id
        }
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
        let session = Session(
            showThumbnails: showThumbnails,
            selectedPath: selectedTab?.url.path,
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