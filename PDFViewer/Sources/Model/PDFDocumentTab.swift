import AppKit
import PDFKit

enum ZoomMode: String, Codable {
    case manual
    case fitWidth
}

/// One open PDF. Owns its own `PDFView` so that scroll position, zoom and the
/// highlighted search hits survive switching tabs.
final class PDFDocumentTab: ObservableObject, Identifiable {
    let id: UUID
    let url: URL
    let title: String
    let document: PDFDocument
    let pdfView: FitWidthPDFView

    @Published private(set) var pageIndex: Int = 0
    let pageCount: Int
    @Published private(set) var zoomMode: ZoomMode = .manual

    @Published var searchText: String = ""
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var selectedMatchIndex: Int = 0

    /// Called whenever something worth persisting changed.
    var onDirty: (() -> Void)?

    private var pageObserver: NSObjectProtocol?
    private var searchWorkItem: DispatchWorkItem?
    private var isRestoring = false
    private var pendingPageIndex: Int?

    init?(url: URL) {
        guard let document = PDFDocument(url: url) else { return nil }

        self.id = UUID()
        self.url = url
        self.document = document
        self.pageCount = document.pageCount
        self.title = url.deletingPathExtension().lastPathComponent

        let view = FitWidthPDFView(frame: .zero)
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 12.0
        // `.textBackgroundColor` follows light/dark mode automatically.
        view.backgroundColor = .textBackgroundColor
        self.pdfView = view
        view.onWidthChange = { [weak self] in
            guard let self else { return }
            self.applyFitWidthIfNeeded()
            self.finishRestoringIfNeeded()
        }

        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak self] _ in
            self?.pageDidChangeInView()
        }
    }

    deinit {
        if let pageObserver {
            NotificationCenter.default.removeObserver(pageObserver)
        }
        searchWorkItem?.cancel()
    }

    // MARK: - Pages

    private func pageDidChangeInView() {
        guard !isRestoring, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard index >= 0 else { return }
        if index != pageIndex {
            pageIndex = index
        }
        onDirty?()
    }

    func go(toPageIndex index: Int) {
        guard let page = document.page(at: index) else { return }
        pdfView.go(to: page)
        if index != pageIndex {
            pageIndex = index
        }
        onDirty?()
    }

    // MARK: - Zoom

    func zoomIn() {
        setScale(pdfView.scaleFactor * 1.25)
    }

    func zoomOut() {
        setScale(pdfView.scaleFactor / 1.25)
    }

    func actualSize() {
        setScale(1.0)
    }

    func fitToWidth() {
        zoomMode = .fitWidth
        applyFitWidthIfNeeded(force: true)
        onDirty?()
    }

    private func setScale(_ proposed: CGFloat) {
        zoomMode = .manual
        let clamped = min(max(proposed, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        pdfView.scaleFactor = clamped
        onDirty?()
    }

    func applyFitWidthIfNeeded(force: Bool = false) {
        guard zoomMode == .fitWidth else { return }
        guard let page = pdfView.currentPage ?? document.page(at: 0) else { return }

        let pageWidth = page.bounds(for: pdfView.displayBox).width
        guard pageWidth > 0, pdfView.bounds.width > 0 else { return }

        let horizontalMargin: CGFloat = 8
        let proposed = (pdfView.bounds.width - horizontalMargin * 2) / pageWidth
        let clamped = min(max(proposed, pdfView.minScaleFactor), pdfView.maxScaleFactor)

        // Guard against a resize feedback loop: only nudge the scale when it
        // is meaningfully different.
        if force || abs(pdfView.scaleFactor - clamped) > clamped * 0.005 {
            pdfView.scaleFactor = clamped
            onDirty?()
        }
    }

    // MARK: - Search

    func scheduleSearch() {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performSearch()
        }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matches = []
            selectedMatchIndex = 0
            pdfView.highlightedSelections = nil
            return
        }

        matches = document.findString(
            query,
            withOptions: [.caseInsensitive, .diacriticInsensitive]
        )
        selectedMatchIndex = 0
        pdfView.highlightedSelections = matches
        if let first = matches.first {
            reveal(first)
        }
    }

    func selectMatch(at index: Int) {
        guard matches.indices.contains(index) else { return }
        selectedMatchIndex = index
        reveal(matches[index])
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        selectMatch(at: (selectedMatchIndex + 1) % matches.count)
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        let count = matches.count
        selectMatch(at: (selectedMatchIndex - 1 + count) % count)
    }

    var matchSummary: String {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        if matches.isEmpty { return "No results" }
        return "\(selectedMatchIndex + 1) of \(matches.count)"
    }

    private func reveal(_ selection: PDFSelection) {
        pdfView.setCurrentSelection(selection, animate: true)
        pdfView.go(to: selection)
    }

    func clearSearch() {
        searchWorkItem?.cancel()
        searchText = ""
        matches = []
        selectedMatchIndex = 0
        pdfView.highlightedSelections = nil
        pdfView.setCurrentSelection(nil, animate: false)
    }

    // MARK: - Restore

    /// Records what to come back to. The actual scroll is deferred until the
    /// view has a real frame — `go(to:)` silently does nothing before that.
    func restore(pageIndex: Int, zoomMode: ZoomMode, scale: Double?) {
        isRestoring = true

        self.zoomMode = zoomMode
        if let scale, scale > 0, zoomMode == .manual {
            pdfView.scaleFactor = CGFloat(scale)
        }

        let clampedIndex = max(0, min(pageIndex, max(0, pageCount - 1)))
        self.pageIndex = clampedIndex
        pendingPageIndex = clampedIndex
    }

    /// Called from the first real layout pass.
    func finishRestoringIfNeeded() {
        guard isRestoring, pdfView.bounds.width > 1 else { return }

        applyFitWidthIfNeeded(force: true)

        if let index = pendingPageIndex, let page = document.page(at: index) {
            pdfView.go(to: page)
        }

        pendingPageIndex = nil
        isRestoring = false
    }
}