import AppKit
import Foundation

/// Groups resources (lectures, past papers, generated summaries and decks)
/// into named workbooks. Persisted to `workbooks.json` in Application Support.
final class WorkbookStore: ObservableObject {
    static let shared = WorkbookStore()

    @Published private(set) var workbooks: [Workbook] = []

    private var saveWorkItem: DispatchWorkItem?

    private init() {
        load()
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
        scheduleSave()
    }

    // MARK: - Folders

    @discardableResult
    func addFolder(named name: String, to workbookID: UUID) -> UUID? {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return nil }
        let folder = WorkbookFolder(name: uniqueFolderName(name, in: index))
        workbooks[index].folders.append(folder)
        scheduleSave()
        return folder.id
    }

    func renameFolder(_ folderID: UUID, in workbookID: UUID, to name: String) {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }),
              let folderIndex = workbooks[index].folders.firstIndex(where: { $0.id == folderID }) else { return }
        workbooks[index].folders[folderIndex].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        scheduleSave()
    }

    func deleteFolder(_ folderID: UUID, from workbookID: UUID) {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }
        workbooks[index].folders.removeAll { $0.id == folderID }
        scheduleSave()
    }

    // MARK: - Items

    func add(_ item: WorkbookItem, to workbookID: UUID, folderID: UUID? = nil) {
        guard let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }

        if let folderID, let folderIndex = workbooks[index].folders.firstIndex(where: { $0.id == folderID }) {
            guard !workbooks[index].folders[folderIndex].items.contains(where: { $0.path == item.path }) else { return }
            workbooks[index].folders[folderIndex].items.append(item)
        } else {
            guard !workbooks[index].items.contains(where: { $0.path == item.path }) else { return }
            workbooks[index].items.append(item)
        }
        scheduleSave()
    }

    func add(_ items: [WorkbookItem], to workbookID: UUID, folderID: UUID? = nil) {
        items.forEach { add($0, to: workbookID, folderID: folderID) }
    }

    func remove(_ item: WorkbookItem, from workbookID: UUID) {
        removeItems([item.id], from: workbookID)
    }

    func removeItems(_ ids: Set<UUID>, from workbookID: UUID) {
        guard !ids.isEmpty, let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }
        workbooks[index].items.removeAll { ids.contains($0.id) }
        for folderIndex in workbooks[index].folders.indices {
            workbooks[index].folders[folderIndex].items.removeAll { ids.contains($0.id) }
        }
        scheduleSave()
    }

    func deleteWorkbooks(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        workbooks.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func deleteFolders(_ ids: Set<UUID>, from workbookID: UUID) {
        guard !ids.isEmpty, let index = workbooks.firstIndex(where: { $0.id == workbookID }) else { return }
        workbooks[index].folders.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    /// Moves items into another container. `index` inserts at a precise spot;
    /// `nil` appends to the end.
    func moveItems(from source: UUID, ids: Set<UUID>, to target: UUID, folderID: UUID?, index: Int? = nil) {
        guard !ids.isEmpty, let sourceIndex = workbooks.firstIndex(where: { $0.id == source }) else { return }

        let sameContainer = source == target
        var moving: [WorkbookItem] = []
        var removedBefore = 0

        var topLevel: [WorkbookItem] = []
        for (position, item) in workbooks[sourceIndex].items.enumerated() {
            if ids.contains(item.id) {
                moving.append(item)
                if sameContainer, folderID == nil, let index, position < index { removedBefore += 1 }
            } else {
                topLevel.append(item)
            }
        }
        workbooks[sourceIndex].items = topLevel

        for folderIndex in workbooks[sourceIndex].folders.indices {
            let isTargetFolder = sameContainer && workbooks[sourceIndex].folders[folderIndex].id == folderID
            var keep: [WorkbookItem] = []
            for (position, item) in workbooks[sourceIndex].folders[folderIndex].items.enumerated() {
                if ids.contains(item.id) {
                    moving.append(item)
                    if isTargetFolder, let index, position < index { removedBefore += 1 }
                } else {
                    keep.append(item)
                }
            }
            workbooks[sourceIndex].folders[folderIndex].items = keep
        }

        guard let targetIndex = workbooks.firstIndex(where: { $0.id == target }) else { return }
        let adjusted = index.map { max(0, $0 - removedBefore) }

        if let folderID, let folderIndex = workbooks[targetIndex].folders.firstIndex(where: { $0.id == folderID }) {
            workbooks[targetIndex].folders[folderIndex].items = insert(moving, into: workbooks[targetIndex].folders[folderIndex].items, at: adjusted)
        } else {
            workbooks[targetIndex].items = insert(moving, into: workbooks[targetIndex].items, at: adjusted)
        }
        scheduleSave()
    }

    private func insert(_ moving: [WorkbookItem], into items: [WorkbookItem], at index: Int?) -> [WorkbookItem] {
        var result = items
        let filtered = moving.filter { move in !result.contains(where: { $0.path == move.path }) }
        let at = min(max(index ?? result.count, 0), result.count)
        result.insert(contentsOf: filtered, at: at)
        return result
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

    func makePDFItems(for urls: [URL]) -> [WorkbookItem] {
        urls.map { makeItem(kind: .pdf, title: $0.deletingPathExtension().lastPathComponent, url: $0) }
    }

    // MARK: - Helpers

    private func uniqueFolderName(_ desired: String, in workbookIndex: Int) -> String {
        let trimmed = desired.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Folder" : trimmed
        let existing = Set(workbooks[workbookIndex].folders.map { $0.name.lowercased() })
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
