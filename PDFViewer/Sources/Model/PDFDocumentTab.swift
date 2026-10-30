import AppKit
import PDFKit

enum ZoomMode: String, Codable {
    case manual
    case fitWidth
}

/// One entry of a PDF's built-in table of contents.
struct PDFOutlineNode: Identifiable {
    /// Position in reading order, unique within one document.
    let id: Int
    let title: String
    let pageIndex: Int?
    let destination: PDFDestination?
    let children: [PDFOutlineNode]?

    static func build(from document: PDFDocument) -> [PDFOutlineNode] {
        guard let root = document.outlineRoot else { return [] }
        var counter = 0

        func children(of item: PDFOutline) -> [PDFOutlineNode] {
            var result: [PDFOutlineNode] = []
            for index in 0..<item.numberOfChildren {
                guard let child = item.child(at: index) else { continue }
                let id = counter
                counter += 1

                let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination
                var pageIndex: Int?
                if let page = destination?.page {
                    let found = document.index(for: page)
                    if found >= 0, found < document.pageCount { pageIndex = found }
                }

                let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let nested = children(of: child)
                result.append(
                    PDFOutlineNode(
                        id: id,
                        title: label.isEmpty ? "Untitled" : label,
                        pageIndex: pageIndex,
                        destination: destination,
                        children: nested.isEmpty ? nil : nested
                    )
                )
            }
            return result
        }

        return children(of: root)
    }

    /// The entry for the section containing `pageIndex`: the one starting
    /// latest at or before that page (deepest entry wins a tie).
    static func current(in nodes: [PDFOutlineNode], pageIndex: Int) -> Int? {
        var best: (id: Int, page: Int)?
        func visit(_ nodes: [PDFOutlineNode]) {
            for node in nodes {
                if let page = node.pageIndex, page <= pageIndex, page >= (best?.page ?? Int.min) {
                    best = (node.id, page)
                }
                if let children = node.children { visit(children) }
            }
        }
        visit(nodes)
        return best?.id
    }
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

    @Published var pageNotes: [Int: String] = [:] {
        didSet { persistAnnotations() }
    }

    /// Highlights and underlines, drawn on the in-memory document only.
    @Published private(set) var highlights: [StoredHighlight] = []
    private var highlightAnnotations: [UUID: [PDFAnnotation]] = [:]

    /// Right-click actions on selected text that need the rest of the app
    /// (the assistant, notes). Receives the text and its first page index.
    var onSelectionCommand: ((SelectionCommand, String, Int) -> Void)?
    @Published var isAnnotatingPages = false

    /// The document's table of contents, empty when it has none.
    private(set) lazy var outline: [PDFOutlineNode] = PDFOutlineNode.build(from: document)

    /// Called whenever something worth persisting changed.
    var onDirty: (() -> Void)?

    /// Called when the user clicks into this tab's PDF, used to focus its pane.
    var onFocus: (() -> Void)?

    enum SelectionCommand {
        case ask
        case explain
        case flashcards
        case addToNote
    }

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
        self.pageNotes = AnnotationStore.load(pdfPath: url.path, title: self.title)

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
            self?.finishRestoringIfNeeded()
        }
        view.onFocus = { [weak self] in
            self?.onFocus?()
        }
        view.contextMenuItems = { [weak self] point in
            self?.contextMenuItems(at: point) ?? []
        }

        for highlight in AnnotationStore.loadHighlights(pdfPath: url.path, title: title) {
            addAnnotations(for: highlight)
            highlights.append(highlight)
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

    func go(to node: PDFOutlineNode) {
        if let destination = node.destination, destination.page != nil {
            pdfView.go(to: destination)
            onDirty?()
        } else if let index = node.pageIndex {
            go(toPageIndex: index)
        }
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
        zoomMode = .manual
        applyFitWidthNow()
        onDirty?()
    }

    private func setScale(_ proposed: CGFloat) {
        zoomMode = .manual
        let clamped = min(max(proposed, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        pdfView.scaleFactor = clamped
        onDirty?()
    }

    /// Fits the current page to the view's width. Applied only when the user
    /// asks for it (or a saved fit-width tab is restored) — never automatically
    /// on layout changes, so opening the side panels can't change the zoom.
    private func applyFitWidthNow() {
        guard let page = pdfView.currentPage ?? document.page(at: 0) else { return }

        let pageWidth = page.bounds(for: pdfView.displayBox).width
        guard pageWidth > 0, pdfView.bounds.width > 0 else { return }

        let horizontalMargin: CGFloat = 8
        let proposed = (pdfView.bounds.width - horizontalMargin * 2) / pageWidth
        pdfView.scaleFactor = min(max(proposed, pdfView.minScaleFactor), pdfView.maxScaleFactor)
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

    // MARK: - Highlights

    private func persistAnnotations() {
        AnnotationStore.save(pageNotes, highlights: highlights, pdfPath: url.path, title: title)
    }

    /// The page the current selection starts on, if there is one.
    var selectionPageIndex: Int? {
        guard let page = pdfView.currentSelection?.pages.first else { return nil }
        let index = document.index(for: page)
        return index >= 0 ? index : nil
    }

    /// The current selection, if it contains any real text.
    var selectedText: String? {
        guard let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return text
    }

    /// Highlights (or underlines) the current text selection. One stored
    /// highlight is made per page the selection touches.
    @discardableResult
    func highlightSelection(color: HighlightColor = .yellow, style: HighlightStyle = .highlight) -> Bool {
        guard let selection = pdfView.currentSelection, selectedText != nil else { return false }

        let lines = selection.selectionsByLine()
        var created: [StoredHighlight] = []

        for page in selection.pages {
            let pageIndex = document.index(for: page)
            guard pageIndex >= 0 else { continue }

            let pageLines = lines.filter { $0.pages.contains(page) }
            let rects = pageLines.map { $0.bounds(for: page) }.filter { $0.width > 0.5 && $0.height > 0.5 }
            guard !rects.isEmpty else { continue }

            let text = pageLines.compactMap(\.string).joined(separator: " ")
            created.append(
                StoredHighlight(
                    id: UUID(),
                    page: pageIndex,
                    rects: rects.map { [$0.origin.x, $0.origin.y, $0.width, $0.height].map { Double($0) } },
                    color: color,
                    style: style,
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        guard !created.isEmpty else { return false }
        for highlight in created {
            addAnnotations(for: highlight)
        }
        highlights.append(contentsOf: created)
        pdfView.clearSelection()
        persistAnnotations()
        return true
    }

    func removeHighlight(id: UUID) {
        for annotation in highlightAnnotations[id] ?? [] {
            annotation.page?.removeAnnotation(annotation)
        }
        highlightAnnotations[id] = nil
        highlights.removeAll { $0.id == id }
        persistAnnotations()
    }

    func recolorHighlight(id: UUID, to color: HighlightColor) {
        guard let index = highlights.firstIndex(where: { $0.id == id }) else { return }
        highlights[index].color = color
        for annotation in highlightAnnotations[id] ?? [] {
            annotation.color = Self.annotationColor(color, style: highlights[index].style)
        }
        persistAnnotations()
    }

    func go(to highlight: StoredHighlight) {
        guard let page = document.page(at: highlight.page) else { return }
        if let rect = highlight.cgRects.first {
            pdfView.go(to: rect, on: page)
        } else {
            pdfView.go(to: page)
        }
        onDirty?()
    }

    private func addAnnotations(for highlight: StoredHighlight) {
        guard let page = document.page(at: highlight.page) else { return }
        let type: PDFAnnotationSubtype = highlight.style == .underline ? .underline : .highlight
        var added: [PDFAnnotation] = []
        for rect in highlight.cgRects {
            let annotation = PDFAnnotation(bounds: rect, forType: type, withProperties: nil)
            annotation.color = Self.annotationColor(highlight.color, style: highlight.style)
            page.addAnnotation(annotation)
            added.append(annotation)
        }
        highlightAnnotations[highlight.id] = added
    }

    private static func annotationColor(_ color: HighlightColor, style: HighlightStyle) -> NSColor {
        style == .underline ? color.nsColor : color.nsColor.withAlphaComponent(0.4)
    }

    /// The highlight under a point in the PDF view, if any.
    private func highlightID(at point: NSPoint) -> UUID? {
        guard let page = pdfView.page(for: point, nearest: false) else { return nil }
        let pagePoint = pdfView.convert(point, to: page)
        for (id, annotations) in highlightAnnotations {
            if annotations.contains(where: { $0.page === page && $0.bounds.insetBy(dx: -2, dy: -2).contains(pagePoint) }) {
                return id
            }
        }
        return nil
    }

    private func contextMenuItems(at point: NSPoint) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        if let text = selectedText {
            let selectionPage = pdfView.currentSelection?.pages.first.map { document.index(for: $0) } ?? pageIndex

            let highlight = NSMenuItem(title: "Highlight", action: nil, keyEquivalent: "")
            highlight.image = NSImage(systemSymbolName: "highlighter", accessibilityDescription: nil)
            let colors = NSMenu()
            for color in HighlightColor.allCases {
                colors.addItem(ClosureMenuItem(color.label, image: "circle.fill", tint: color.nsColor) { [weak self] in
                    self?.highlightSelection(color: color)
                })
            }
            colors.addItem(.separator())
            colors.addItem(ClosureMenuItem("Underline", image: "underline") { [weak self] in
                self?.highlightSelection(color: .blue, style: .underline)
            })
            highlight.submenu = colors
            items.append(highlight)

            if onSelectionCommand != nil {
                items.append(.separator())
                items.append(ClosureMenuItem("Ask Assistant About Selection", image: "sparkles") { [weak self] in
                    self?.onSelectionCommand?(.ask, text, selectionPage)
                })
                items.append(ClosureMenuItem("Explain Selection", image: "lightbulb") { [weak self] in
                    self?.onSelectionCommand?(.explain, text, selectionPage)
                })
                items.append(ClosureMenuItem("Make Flashcards from Selection", image: "rectangle.on.rectangle") {
                    [weak self] in
                    self?.onSelectionCommand?(.flashcards, text, selectionPage)
                })
                items.append(ClosureMenuItem("Add Selection to Note", image: "note.text.badge.plus") { [weak self] in
                    self?.onSelectionCommand?(.addToNote, text, selectionPage)
                })
            }
        } else if let id = highlightID(at: point) {
            let color = NSMenuItem(title: "Highlight Colour", action: nil, keyEquivalent: "")
            let colors = NSMenu()
            for option in HighlightColor.allCases {
                let item = ClosureMenuItem(option.label, image: "circle.fill", tint: option.nsColor) { [weak self] in
                    self?.recolorHighlight(id: id, to: option)
                }
                item.state = highlights.first(where: { $0.id == id })?.color == option ? .on : .off
                colors.addItem(item)
            }
            color.submenu = colors
            items.append(color)
            items.append(ClosureMenuItem("Remove Highlight", image: "eraser") { [weak self] in
                self?.removeHighlight(id: id)
            })
        }

        return items
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

        if zoomMode == .fitWidth {
            applyFitWidthNow()
            zoomMode = .manual
        }

        if let index = pendingPageIndex, let page = document.page(at: index) {
            pdfView.go(to: page)
        }

        pendingPageIndex = nil
        isRestoring = false
    }
}
