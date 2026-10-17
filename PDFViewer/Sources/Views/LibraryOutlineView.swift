import AppKit
import SwiftUI

/// Drag payload carried while dragging items inside the sidebar.
struct WorkbookDragItems: Codable {
    let sourceWorkbook: UUID
    let ids: [UUID]

    init(sourceWorkbook: UUID, ids: [UUID]) {
        self.sourceWorkbook = sourceWorkbook
        self.ids = ids
    }

    init?(jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(WorkbookDragItems.self, from: data) else {
            return nil
        }
        self = decoded
    }

    var jsonString: String {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

/// One row in the library tree.
final class LibraryNode: NSObject {
    enum Kind {
        case workbook(Workbook)
        case folder(WorkbookFolder, workbookID: UUID)
        case item(WorkbookItem, workbookID: UUID)
    }

    let id: UUID
    let kind: Kind
    let children: [LibraryNode]

    init(id: UUID, kind: Kind, children: [LibraryNode] = []) {
        self.id = id
        self.kind = kind
        self.children = children
    }

    var title: String {
        switch kind {
        case .workbook(let workbook): return workbook.name
        case .folder(let folder, _): return folder.name
        case .item(let item, _): return item.title
        }
    }

    var symbol: String {
        switch kind {
        case .workbook: return "folder.fill"
        case .folder: return "folder"
        case .item(let item, _):
            switch item.kind {
            case .pdf: return "doc.text"
            case .summary: return "doc.plaintext"
            case .deck: return "rectangle.on.rectangle"
            case .quiz: return "checklist"
            }
        }
    }

    var isExpandable: Bool { !children.isEmpty }
}

/// A VS Code–style library tree with multi-select and precise drag/drop.
struct LibraryOutlineView: NSViewRepresentable {
    @ObservedObject var store: WorkbookStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = MenuOutlineView()
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.menuProvider = { [weak coordinator = context.coordinator, weak outlineView] row in
            guard let outlineView else { return nil }
            return coordinator?.menu(forRow: row, in: outlineView)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.indentationPerLevel = 14
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.selectionHighlightStyle = .regular
        outlineView.style = .plain
        outlineView.backgroundColor = .clear
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.handleDoubleClick)

        outlineView.registerForDraggedTypes([Coordinator.dragType, .fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        context.coordinator.outlineView = outlineView
        context.coordinator.reloadNow()

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.reload()
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let dragType = NSPasteboard.PasteboardType("com.example.PDFViewer.workbookItems")

        let store: WorkbookStore
        weak var outlineView: NSOutlineView?
        private var roots: [LibraryNode] = []
        private var expandedIDs: Set<UUID> = []
        private var menuNodes: [LibraryNode] = []
        private var reloadScheduled = false
        private var isDragging = false
        private var reloadAfterDrag = false

        private static let expansionKey = "libraryExpandedIDs"

        init(store: WorkbookStore) {
            self.store = store
            expandedIDs = Set(
                (UserDefaults.standard.array(forKey: Self.expansionKey) as? [String] ?? [])
                    .compactMap { UUID(uuidString: $0) }
            )
        }

        private func persistExpansion() {
            UserDefaults.standard.set(expandedIDs.map(\.uuidString), forKey: Self.expansionKey)
        }

        // MARK: - Tree

        /// Coalesces reloads and runs them after the current update, so we never
        /// rebuild the outline view from inside its own delegate callbacks.
        func reload() {
            guard !reloadScheduled else { return }
            reloadScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.reloadScheduled = false
                self?.performReload()
            }
        }

        func reloadNow() {
            reloadScheduled = false
            performReload()
        }

        private func performReload() {
            guard !isDragging else {
                reloadAfterDrag = true
                return
            }

            captureExpansion()
            persistExpansion()

            roots = store.workbooks.map { workbook in
                let folderNodes = workbook.folders.map { folder in
                    LibraryNode(
                        id: folder.id,
                        kind: .folder(folder, workbookID: workbook.id),
                        children: folder.items.map { LibraryNode(id: $0.id, kind: .item($0, workbookID: workbook.id)) }
                    )
                }
                let itemNodes = workbook.items.map { LibraryNode(id: $0.id, kind: .item($0, workbookID: workbook.id)) }
                return LibraryNode(id: workbook.id, kind: .workbook(workbook), children: folderNodes + itemNodes)
            }

            guard let outlineView else { return }
            let selected = Set((0..<outlineView.numberOfSelectedRows).compactMap { outlineView.item(atRow: $0) as? LibraryNode }.map(\.id))
            outlineView.reloadData()
            restoreExpansion()
            restoreSelection(selected)
        }

        /// Records which nodes are currently expanded straight from the outline
        /// view (before the tree is rebuilt), so reloading preserves them.
        private func captureExpansion() {
            guard let outlineView else { return }
            func walk(_ node: LibraryNode) {
                if outlineView.isItemExpanded(node) {
                    expandedIDs.insert(node.id)
                } else {
                    expandedIDs.remove(node.id)
                }
                for child in node.children {
                    walk(child)
                }
            }
            roots.forEach(walk)
        }

        private func restoreExpansion() {
            for root in roots {
                expandIfNeeded(root)
            }
        }

        private func expandIfNeeded(_ node: LibraryNode) {
            guard let outlineView else { return }
            if expandedIDs.contains(node.id) {
                outlineView.expandItem(node)
            }
            for child in node.children {
                expandIfNeeded(child)
            }
        }

        private func restoreSelection(_ ids: Set<UUID>) {
            guard let outlineView, !ids.isEmpty else { return }
            var indexes = IndexSet()
            for row in 0..<outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? LibraryNode, ids.contains(node.id) {
                    indexes.insert(row)
                }
            }
            outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        }

        private func node(at row: Int) -> LibraryNode? {
            guard let outlineView, row >= 0 else { return nil }
            return outlineView.item(atRow: row) as? LibraryNode
        }

        // MARK: - Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? LibraryNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? LibraryNode)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? LibraryNode)?.isExpandable ?? false
        }

        // MARK: - Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? LibraryNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("LibraryCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? Self.makeCell(identifier)
            cell.textField?.stringValue = node.title
            cell.imageView?.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
            return cell
        }

        static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = NSFont.systemFont(ofSize: 12.5)
            textField.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView, !outlineView.selectedRowIndexes.isEmpty else { return }
            var workbookID: UUID?
            for row in outlineView.selectedRowIndexes {
                guard let node = outlineView.item(atRow: row) as? LibraryNode else { continue }
                switch node.kind {
                case .workbook(let workbook): workbookID = workbook.id
                case .folder(_, let id): workbookID = id
                case .item(_, let id): workbookID = id
                }
            }
            if store.activeWorkbookID != workbookID {
                store.activeWorkbookID = workbookID
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? LibraryNode {
                expandedIDs.insert(node.id)
                persistExpansion()
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? LibraryNode {
                expandedIDs.remove(node.id)
                persistExpansion()
            }
        }

        // MARK: - Dragging

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            isDragging = true
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            if reloadAfterDrag {
                reloadAfterDrag = false
                reload()
            }
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? LibraryNode, case .item(let workbookItem, let workbookID) = node.kind else {
                return nil
            }

            let selectedItemIDs = selectionItemIDs()
            let ids = selectedItemIDs.contains(workbookItem.id) ? Array(selectedItemIDs) : [workbookItem.id]

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(
                WorkbookDragItems(sourceWorkbook: workbookID, ids: ids).jsonString,
                forType: Self.dragType
            )
            return pasteboardItem
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            let hasItems = info.draggingPasteboard.availableType(from: [Self.dragType]) != nil
            let hasFiles = info.draggingPasteboard.availableType(from: [.fileURL]) != nil
            guard hasItems || hasFiles else { return [] }

            if hasItems {
                if index == NSOutlineViewDropOnItemIndex, let node = item as? LibraryNode {
                    switch node.kind {
                    case .workbook, .folder:
                        outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
                        return .move
                    case .item:
                        let (parent, childIndex) = insertionPoint(outlineView, over: node, info: info)
                        outlineView.setDropItem(parent, dropChildIndex: childIndex)
                        return .move
                    }
                }
                if item == nil, index != NSOutlineViewDropOnItemIndex {
                    return [] // no reordering of whole workbooks
                }
                return .move
            }

            // External files: only onto a workbook or folder.
            if index == NSOutlineViewDropOnItemIndex, let node = item as? LibraryNode {
                switch node.kind {
                case .workbook, .folder: return .copy
                case .item: return []
                }
            }
            return []
        }

        private func insertionPoint(_ outlineView: NSOutlineView, over node: LibraryNode, info: NSDraggingInfo) -> (Any?, Int) {
            let row = outlineView.row(forItem: node)
            guard row >= 0 else { return (outlineView.parent(forItem: node), 0) }
            let parent = outlineView.parent(forItem: node)
            let indexInParent = outlineView.childIndex(forItem: node)
            let rowRect = outlineView.rect(ofRow: row)
            let y = outlineView.convert(info.draggingLocation, from: nil).y
            let after = y > rowRect.midY
            return (parent, after ? indexInParent + 1 : indexInParent)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            if let json = info.draggingPasteboard.string(forType: Self.dragType),
               let payload = WorkbookDragItems(jsonString: json) {
                guard let target = target(for: item, index: index) else { return false }
                store.moveItems(
                    from: payload.sourceWorkbook,
                    ids: Set(payload.ids),
                    to: target.workbookID,
                    folderID: target.folderID,
                    index: target.index
                )
                return true
            }

            if info.draggingPasteboard.availableType(from: [.fileURL]) != nil {
                return acceptFileDrop(info, item: item)
            }
            return false
        }

        private func target(for item: Any?, index: Int) -> (workbookID: UUID, folderID: UUID?, index: Int?)? {
            let insertion = index == NSOutlineViewDropOnItemIndex ? nil : index
            guard let node = item as? LibraryNode else { return nil }
            switch node.kind {
            case .workbook(let workbook):
                return (workbook.id, nil, insertion)
            case .folder(let folder, let workbookID):
                return (workbookID, folder.id, insertion)
            case .item:
                return nil
            }
        }

        private func acceptFileDrop(_ info: NSDraggingInfo, item: Any?) -> Bool {
            guard let node = item as? LibraryNode else { return false }
            let workbookID: UUID
            let folderID: UUID?
            switch node.kind {
            case .workbook(let workbook): workbookID = workbook.id; folderID = nil
            case .folder(let folder, let workbookIDValue): workbookID = workbookIDValue; folderID = folder.id
            case .item: return false
            }

            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { return false }
            store.add(store.makePDFItems(for: pdfs), to: workbookID, folderID: folderID)
            return true
        }

        // MARK: - Selection / opening

        private func selectionItemIDs() -> Set<UUID> {
            guard let outlineView else { return [] }
            var result: Set<UUID> = []
            for row in outlineView.selectedRowIndexes {
                if case .item(let item, _)? = (outlineView.item(atRow: row) as? LibraryNode)?.kind {
                    result.insert(item.id)
                }
            }
            return result
        }

        @objc func handleDoubleClick() {
            guard let outlineView else { return }
            let row = outlineView.clickedRow
            guard let node = node(at: row), case .item(let item, _) = node.kind else {
                outlineView.expandItem(node(at: row))
                return
            }
            open(item)
        }

        private func open(_ item: WorkbookItem) {
            guard let url = store.url(for: item) else {
                LibraryStore.shared.errorMessage = "“\(item.title)” could not be found. It may have been moved or deleted."
                return
            }

            switch item.kind {
            case .pdf:
                LibraryStore.shared.open(urls: [url])
            case .summary:
                Task { @MainActor in
                    AgentChatModel.shared.openSavedSummary(
                        AgentChatModel.SavedSummary(id: url.path, title: item.title, url: url, modified: .distantPast)
                    )
                }
            case .deck:
                Task { @MainActor in
                    AgentChatModel.shared.openSavedDeck(
                        AgentChatModel.SavedDeck(id: url.path, title: item.title, url: url, cardCount: 0, modified: .distantPast)
                    )
                }
            case .quiz:
                Task { @MainActor in
                    AgentChatModel.shared.openSavedQuiz(at: url)
                }
            }
        }

        // MARK: - Context menu

        func menu(forRow row: Int, in outlineView: NSOutlineView) -> NSMenu? {
            if row >= 0, !outlineView.selectedRowIndexes.contains(row) {
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }

            menuNodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? LibraryNode }
            guard let clicked = node(at: row) else { return nil }
            menuClickedNode = clicked

            let menu = NSMenu()
            switch clicked.kind {
            case .workbook(let workbook):
                add(menu, "New Folder…", #selector(menuNewFolder))
                add(menu, "Add Files…", #selector(menuAddFiles))
                add(menu, "Add Current Document", #selector(menuAddCurrent))
                menu.addItem(.separator())
                add(menu, "Rename…", #selector(menuRename))
                add(menu, "Delete", #selector(menuDelete))
                menuItemsContext = (workbook, nil)
            case .folder(let folder, let workbookID):
                add(menu, "Add Files…", #selector(menuAddFiles))
                add(menu, "Add Current Document", #selector(menuAddCurrent))
                menu.addItem(.separator())
                add(menu, "Rename Folder…", #selector(menuRenameFolder))
                add(menu, "Delete Folder", #selector(menuDeleteFolder))
                menuItemsContext = (nil, folder.id)
                menuWorkbookID = workbookID
            case .item:
                add(menu, "Open", #selector(menuOpen))
                add(menu, "Show in Finder", #selector(menuReveal))
                menu.addItem(.separator())
                add(menu, "Remove from Workbook", #selector(menuRemove))
            }
            return menu
        }

        private var menuItemsContext: (workbook: Workbook?, folderID: UUID?)?
        private var menuWorkbookID: UUID?
        private var menuClickedNode: LibraryNode?

        private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        private var clickedWorkbookID: UUID? {
            switch menuClickedNode?.kind {
            case .workbook(let workbook): return workbook.id
            case .item(_, let workbookID): return workbookID
            default: return menuWorkbookID
            }
        }

        @objc private func menuOpen() {
            if case .item(let item, _)? = menuClickedNode?.kind { open(item) }
        }

        @objc private func menuReveal() {
            if case .item(let item, _)? = menuClickedNode?.kind, let url = store.url(for: item) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }

        @objc private func menuRemove() {
            guard case .item(let clickedItem, let workbookID)? = menuClickedNode?.kind else { return }

            var ids = Set(menuNodes.compactMap { node -> UUID? in
                if case .item(let item, _) = node.kind { return item.id }
                return nil
            })
            if ids.isEmpty {
                ids = [clickedItem.id]
            }
            store.removeItems(ids, from: workbookID)
        }

        @objc private func menuNewFolder() {
            guard let workbook = menuItemsContext?.workbook,
                  let name = prompt("New Folder", "Name this folder.", "Folder") else { return }
            if let id = store.addFolder(named: name, to: workbook.id) {
                expandedIDs.insert(id)
            }
        }

        @objc private func menuAddFiles() {
            let workbookID = clickedWorkbookID
            guard let workbookID,
                  let workbook = store.workbooks.first(where: { $0.id == workbookID }) else { return }
            let folderID = menuItemsContext?.folderID
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.pdf]
            panel.message = "Add PDFs to “\(workbook.name)”"
            guard panel.runModal() == .OK else { return }
            store.add(store.makePDFItems(for: panel.urls), to: workbookID, folderID: folderID)
        }

        @objc private func menuAddCurrent() {
            let workbookID = clickedWorkbookID
            guard let workbookID, let tab = LibraryStore.shared.activeTab else { return }
            let folderID = menuItemsContext?.folderID
            store.add(store.makeItem(kind: .pdf, title: tab.title, url: tab.url), to: workbookID, folderID: folderID)
        }

        @objc private func menuRename() {
            guard let workbook = menuItemsContext?.workbook,
                  let name = prompt("Rename Workbook", "Enter a new name.", workbook.name) else { return }
            store.rename(workbook, to: name)
        }

        @objc private func menuDelete() {
            guard let workbook = menuItemsContext?.workbook else { return }
            store.delete(workbook)
        }

        @objc private func menuRenameFolder() {
            guard let workbookID = menuWorkbookID, let folderID = menuItemsContext?.folderID,
                  let folder = store.workbooks.first(where: { $0.id == workbookID })?.folders.first(where: { $0.id == folderID }),
                  let name = prompt("Rename Folder", "Enter a new name.", folder.name) else { return }
            store.renameFolder(folderID, in: workbookID, to: name)
        }

        @objc private func menuDeleteFolder() {
            guard let workbookID = menuWorkbookID, let folderID = menuItemsContext?.folderID else { return }
            store.deleteFolder(folderID, from: workbookID)
        }

        private func prompt(_ title: String, _ message: String, _ initial: String) -> String? {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = initial
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            return field.stringValue
        }
    }
}

/// Outline view that asks the coordinator for the right-click menu.
final class MenuOutlineView: NSOutlineView {
    var menuProvider: ((Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        return menuProvider?(row)
    }
}
