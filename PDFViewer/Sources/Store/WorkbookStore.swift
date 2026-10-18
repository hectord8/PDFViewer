import AppKit
import Foundation

/// Groups resources (lectures, past papers, generated summaries and decks)
/// into named workbooks. Persisted to `workbooks.json` in Application Support.
final class WorkbookStore: ObservableObject {
    static let shared = WorkbookStore()

    @Published private(set) var workbooks: [Workbook] = []

    /// The workbook whose files are shown in the workbook tab strip.
    @Published var activeWorkbookID: UUID? {
        didSet {
            if let id = activeWorkbookID {
                UserDefaults.standard.set(id.uuidString, forKey: Self.activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.activeKey)
            }
        }
    }

    private static let activeKey = "activeWorkbookID"
    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
        restoreActiveWorkbook()
    }

    private func restoreActiveWorkbook() {
        guard let stored = UserDefaults.standard.string(forKey: Self.activeKey),
              let id = UUID(uuidString: stored),
              workbooks.contains(where: { $0.id == id }) else {
            return
        }
        activeWorkbookID = id
    }

    // MARK: - Persistence

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "PDFViewer", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("workbooks.json", isDirectory: false)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Workbook].self, from: data) else {
            return
        }
        workbooks = decoded
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(workbooks).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("PDFViewer: could not save workbooks: \(error.localizedDescription)")
        }
    }

    // MARK: - Workbooks

    @discardableResult
    func createWorkbook(named name: String) -> Workbook {
        let workbook = Workbook(name: uniqueName(name))
        workbooks.append(workbook)
        scheduleSave()
        return workbook
    }

    func rename(_ workbook: Workbook, to name: String) {
        guard let index = workbooks.firstIndex(where: { $0.id == workbook.id }) else { return }
        workbooks[index].name = uniqueName(name, excluding: workbook.id)
        scheduleSave()
    }

    func delete(_ workbook: Workbook) {
        workbooks.removeAll { $0.id == workbook.id }
        if activeWorkbookID == workbook.id {
            activeWorkbookID = nil
        }
        scheduleSave()
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(named name: String, to workbookID: UUID, parentFolderID: UUID? = nil) -> UUID? {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return nil }

        if let parentFolderID {
            var created: UUID?
            _ = withFolder(parentFolderID, in: &workbooks[index].folders) { folder in
                let new = WorkbookFolder(name: uniqueFolderName(name, among: folder.folders))
                folder.folders.append(new)
                created = new.id
            }
            guard created != nil else { return nil }
            scheduleSave()
            return created
        }

        let folder = WorkbookFolder(name: uniqueFolderName(name, among: workbooks[index].folders))
        workbooks[index].folders.append(folder)
        scheduleSave()
        return folder.id
    }

    func renameFolder(_ folderID: UUID, in workbookID: UUID, to name: String) {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }
        _ = withFolder(folderID, in: &workbooks[index].folders) { folder in
            folder.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        scheduleSave()
    }

    func deleteFolder(_ folderID: UUID, from workbookID: UUID) {
        deleteFolders([folderID], from: workbookID)
    }

    // MARK: - Items

    func add(_ item: WorkbookItem, to workbookID: UUID, folderID: UUID? = nil) {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }

        if let folderID {
            var added = false
            _ = withFolder(folderID, in: &workbooks[index].folders) { folder in
                guard !folder.items.contains(where: { $0.path == item.path }) else { return }
                folder.items.append(item)
                added = true
            }
            if added {
                scheduleSave()
                return
            }
        }

        guard !workbooks[index].items.contains(where: { $0.path == item.path }) else { return }
        workbooks[index].items.append(item)
        scheduleSave()
    }

    func add(_ items: [WorkbookItem], to workbookID: UUID, folderID: UUID? = nil) {
        items.forEach { add($0, to: workbookID, folderID: folderID) }
    }

    func remove(_ item: WorkbookItem, from workbookID: UUID) {
        removeItems([item.id], from: workbookID)
    }

    /// Updates an item's title/path (used after renaming the file on disk).
    func updateItem(id: UUID, in workbookID: UUID, title: String, path: String, bookmark: Data?) {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }

        func update(_ items: inout [WorkbookItem]) -> Bool {
            for position in items.indices where items[position].id == id {
                items[position].title = title
                items[position].path = path
                items[position].bookmark = bookmark
                return true
            }
            return false
        }

        func updateFolders(_ folders: inout [WorkbookFolder]) -> Bool {
            for position in folders.indices {
                if update(&folders[position].items) { return true }
                if updateFolders(&folders[position].folders) { return true }
            }
            return false
        }

        if update(&workbooks[index].items) {
            scheduleSave()
            return
        }
        if updateFolders(&workbooks[index].folders) {
            scheduleSave()
        }
    }

    func removeItems(_ ids: Set<UUID>, from workbookID: UUID) {
        guard !ids.isEmpty, let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }
        workbooks[index].items.removeAll { ids.contains($0.id) }
        var discarded: [WorkbookItem] = []
        extractItems(ids, from: &workbooks[index].folders, into: &discarded)
        scheduleSave()
    }

    func deleteWorkbooks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        workbooks.removeAll { ids.contains($0.id) }
        if let active = activeWorkbookID, ids.contains(active) {
            activeWorkbookID = nil
        }
        scheduleSave()
    }

    /// Moves folders to another workbook, into a folder, or to a new position.
    func moveFolders(_ ids: Set<UUID>, from source: UUID, to target: UUID, folderID: UUID?, index: Int?) {
        guard !ids.isEmpty, let sourceIndex = workbooks.firstIndex(where: { $0.id == source }) else { return }
        guard !(ids.contains(where: { $0 == folderID })) else { return }

        let moving = removeFolders(ids, from: &workbooks[sourceIndex].folders)
        guard !moving.isEmpty else { return }
        if let folderID, moving.contains(where: { containsFolder(folderID, in: [$0]) }) { return }

        guard let targetIndex = workbooks.firstIndex(where: { $0.id == target }) else { return }

        if let folderID {
            var inserted = false
            _ = withFolder(folderID, in: &workbooks[targetIndex].folders) { folder in
                insertFolders(moving, into: &folder.folders, at: index)
                inserted = true
            }
            if !inserted {
                insertFolders(moving, into: &workbooks[targetIndex].folders, at: index)
            }
        } else {
            insertFolders(moving, into: &workbooks[targetIndex].folders, at: index)
        }
        scheduleSave()
    }

    func deleteFolders(_ ids: Set<UUID>, from workbookID: UUID) {
        guard !ids.isEmpty, let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }
        _ = removeFolders(ids, from: &workbooks[index].folders)
        scheduleSave()
    }

    /// Moves items into another container (workbook or folder). `index` inserts
    /// at a precise spot within that container; `nil` appends.
    func moveItems(from source: UUID, ids: Set<UUID>, to target: UUID, folderID: UUID?, index: Int? = nil) {
        guard !ids.isEmpty, let sourceIndex = workbooks.firstIndex(where: { $0.id == source }) else { return }

        var moving: [WorkbookItem] = []
        var topLevel: [WorkbookItem] = []
        for item in workbooks[sourceIndex].items {
            if ids.contains(item.id) { moving.append(item) } else { topLevel.append(item) }
        }
        workbooks[sourceIndex].items = topLevel
        extractItems(ids, from: &workbooks[sourceIndex].folders, into: &moving)

        guard let targetIndex = workbooks.firstIndex(where: { $0.id == target }) else { return }

        if let folderID {
            var inserted = false
            _ = withFolder(folderID, in: &workbooks[targetIndex].folders) { folder in
                folder.items = insertItems(moving, into: folder.items, at: index)
                inserted = true
            }
            if !inserted {
                workbooks[targetIndex].items = insertItems(moving, into: workbooks[targetIndex].items, at: index)
            }
        } else {
            workbooks[targetIndex].items = insertItems(moving, into: workbooks[targetIndex].items, at: index)
        }
        scheduleSave()
    }

    // MARK: - Recursive helpers

    @discardableResult
    private func withFolder(
        _ id: UUID,
        in folders: inout [WorkbookFolder],
        _ body: (inout WorkbookFolder) -> Void
    ) -> Bool {
        for index in folders.indices {
            if folders[index].id == id {
                body(&folders[index])
                return true
            }
            if withFolder(id, in: &folders[index].folders, body) {
                return true
            }
        }
        return false
    }

    private func removeFolders(_ ids: Set<UUID>, from folders: inout [WorkbookFolder]) -> [WorkbookFolder] {
        var removed: [WorkbookFolder] = []
        var keep: [WorkbookFolder] = []
        for folder in folders {
            if ids.contains(folder.id) {
                removed.append(folder)
            } else {
                var copy = folder
                removed.append(contentsOf: removeFolders(ids, from: &copy.folders))
                keep.append(copy)
            }
        }
        folders = keep
        return removed
    }

    private func insertFolders(_ moving: [WorkbookFolder], into container: inout [WorkbookFolder], at index: Int?) {
        let at = min(max(index ?? container.count, 0), container.count)
        let filtered = moving.filter { move in !container.contains(where: { $0.id == move.id }) }
        container.insert(contentsOf: filtered, at: at)
    }

    private func extractItems(_ ids: Set<UUID>, from folders: inout [WorkbookFolder], into moving: inout [WorkbookItem]) {
        for index in folders.indices {
            var keep: [WorkbookItem] = []
            for item in folders[index].items {
                if ids.contains(item.id) { moving.append(item) } else { keep.append(item) }
            }
            folders[index].items = keep
            extractItems(ids, from: &folders[index].folders, into: &moving)
        }
    }

    private func insertItems(_ moving: [WorkbookItem], into items: [WorkbookItem], at index: Int?) -> [WorkbookItem] {
        var result = items
        let filtered = moving.filter { move in !result.contains(where: { $0.path == move.path }) }
        let at = min(max(index ?? result.count, 0), result.count)
        result.insert(contentsOf: filtered, at: at)
        return result
    }

    private func containsFolder(_ id: UUID, in folders: [WorkbookFolder]) -> Bool {
        for folder in folders {
            if folder.id == id || containsFolder(id, in: folder.folders) {
                return true
            }
        }
        return false
    }

    func url(for item: WorkbookItem) -> URL? {
        SessionStore.resolve(path: item.path, bookmark: item.bookmark)
    }

    func makeItem(kind: WorkbookItemKind, title: String, url: URL) -> WorkbookItem {
        WorkbookItem(
            kind: kind,
            title: title,
            path: url.path,
            bookmark: SessionStore.makeBookmark(for: url)
        )
    }

    func makeItems(for urls: [URL]) -> [WorkbookItem] {
        urls.map { url in
            let kind: WorkbookItemKind = url.pathExtension.lowercased() == "pdf" ? .pdf : .file
            return makeItem(kind: kind, title: url.deletingPathExtension().lastPathComponent, url: url)
        }
    }

    func makePDFItems(for urls: [URL]) -> [WorkbookItem] {
        urls.map { makeItem(kind: .pdf, title: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }

    /// Adds files and/or folders (any file type). A folder becomes a new
    /// workbook folder containing every file found inside it (recursively).
    func importItems(from urls: [URL], to workbookID: UUID, folderID: UUID?) {
        var looseFiles: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let files = Self.files(in: url)
                guard !files.isEmpty else { continue }
                let target = addFolder(named: url.lastPathComponent, to: workbookID, parentFolderID: folderID) ?? folderID
                add(makeItems(for: files), to: workbookID, folderID: target)
            } else {
                looseFiles.append(url)
            }
        }

        if !looseFiles.isEmpty {
            add(makeItems(for: looseFiles), to: workbookID, folderID: folderID)
        }
    }

    private static func files(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result
    }

    // MARK: - Helpers

    private func uniqueFolderName(_ desired: String, among siblings: [WorkbookFolder]) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Folder" : trimmed
        let existing = Set(siblings.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var suffix = 1
        while existing.contains("\(base) \(suffix)".lowercased()) { suffix += 1 }
        return "\(base) \(suffix)"
    }

    private func uniqueName(_ desired: String, excluding id: UUID? = nil) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Workbook" : trimmed
        let existing = Set(workbooks.filter { $0.id != id }.map { $0.name.lowercased() })

        if !existing.contains(base.lowercased()) { return base }

        var suffix = 1
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}
