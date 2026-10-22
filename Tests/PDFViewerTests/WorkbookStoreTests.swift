import Foundation
import Testing
#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct WorkbookStoreTests {
    private func makeStore(seedDefaults: (UserDefaults) -> Void = { _ in }) -> (WorkbookStore, URL, UserDefaults) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFViewerTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "PDFViewerTests-\(UUID().uuidString)")!
        seedDefaults(defaults)
        let store = WorkbookStore(defaults: defaults, storageDirectory: dir)
        return (store, dir, defaults)
    }

    private func item(_ path: String) -> WorkbookItem {
        WorkbookItem(kind: .pdf, title: URL(fileURLWithPath: path).lastPathComponent, path: path)
    }

    @Test func createWorkbookAppendsAndUniquifiesNames() {
        let (store, _, _) = makeStore()

        let first = store.createWorkbook(named: "Lectures")
        let second = store.createWorkbook(named: "Lectures")

        #expect(store.workbooks.count == 2)
        #expect(first.name == "Lectures")
        #expect(second.name == "Lectures 1")
    }

    @Test func renameUniquifiesAgainstSiblings() {
        let (store, _, _) = makeStore()
        let first = store.createWorkbook(named: "A")
        let second = store.createWorkbook(named: "B")

        store.rename(second, to: "A")

        #expect(second.id != first.id)
        #expect(store.workbooks.first { $0.id == second.id }?.name == "A 1")
    }

    @Test func selectWorkbookValidatesAndClears() {
        let (store, _, _) = makeStore()
        let workbook = store.createWorkbook(named: "Lectures")

        store.selectWorkbook(workbook.id)
        #expect(store.activeWorkbookID == workbook.id)

        store.selectWorkbook(nil)
        #expect(store.activeWorkbookID == nil)

        store.selectWorkbook(UUID())
        #expect(store.activeWorkbookID == nil)
    }

    @Test func deletingActiveWorkbookClearsSelection() {
        let (store, _, _) = makeStore()
        let first = store.createWorkbook(named: "A")
        let second = store.createWorkbook(named: "B")

        store.selectWorkbook(first.id)
        store.delete(second)

        #expect(store.activeWorkbookID == first.id)

        store.delete(first)
        #expect(store.activeWorkbookID == nil)
    }

    @Test func deleteWorkbooksClearsSelectionOnlyWhenActiveDeleted() {
        let (store, _, _) = makeStore()
        let first = store.createWorkbook(named: "A")
        let second = store.createWorkbook(named: "B")

        store.selectWorkbook(first.id)
        store.deleteWorkbooks([second.id])
        #expect(store.activeWorkbookID == first.id)

        store.deleteWorkbooks([first.id])
        #expect(store.activeWorkbookID == nil)
        #expect(store.workbooks.isEmpty)
    }

    @Test func addingFoldersAndItems() {
        let (store, _, _) = makeStore()
        let workbook = store.createWorkbook(named: "Lectures")

        let folderID = store.addFolder(named: "Week 1", to: workbook.id)
        #expect(folderID != nil)

        store.add(item("/tmp/notes.pdf"), to: workbook.id, folderID: folderID)
        store.add(item("/tmp/slides.pdf"), to: workbook.id)

        let reloaded = store.workbooks.first { $0.id == workbook.id }
        #expect(reloaded?.items.count == 1)
        #expect(reloaded?.folders.first?.items.count == 1)
        #expect(reloaded?.containsPath("/tmp/notes.pdf") == true)
        #expect(reloaded?.containsPath("/tmp/slides.pdf") == true)
    }

    @Test func addingDuplicatePathIsIgnored() {
        let (store, _, _) = makeStore()
        let workbook = store.createWorkbook(named: "Lectures")

        store.add(item("/tmp/notes.pdf"), to: workbook.id)
        store.add(item("/tmp/notes.pdf"), to: workbook.id)

        #expect(store.workbooks.first { $0.id == workbook.id }?.items.count == 1)
    }

    @Test func removingItemsByID() {
        let (store, _, _) = makeStore()
        let workbook = store.createWorkbook(named: "Lectures")
        let one = item("/tmp/one.pdf")
        let two = item("/tmp/two.pdf")
        store.add(one, to: workbook.id)
        store.add(two, to: workbook.id)

        store.removeItems([one.id], from: workbook.id)

        #expect(store.workbooks.first { $0.id == workbook.id }?.items.map(\.path) == ["/tmp/two.pdf"])
    }

    @Test func movingItemsBetweenWorkbooks() {
        let (store, _, _) = makeStore()
        let source = store.createWorkbook(named: "Source")
        let target = store.createWorkbook(named: "Target")
        let one = item("/tmp/one.pdf")
        store.add(one, to: source.id)

        store.moveItems(from: source.id, ids: [one.id], to: target.id, folderID: nil)

        #expect(store.workbooks.first { $0.id == source.id }?.items.isEmpty == true)
        #expect(store.workbooks.first { $0.id == target.id }?.items.map(\.path) == ["/tmp/one.pdf"])
    }

    @Test func roundTripsThroughPersistence() throws {
        let (store, dir, _) = makeStore()
        let workbook = store.createWorkbook(named: "Lectures")
        store.add(item("/tmp/notes.pdf"), to: workbook.id)
        store.saveNow()

        let reloaded = WorkbookStore(defaults: UserDefaults(suiteName: "PDFViewerTests-\(UUID().uuidString)")!, storageDirectory: dir)

        #expect(reloaded.workbooks.count == 1)
        #expect(reloaded.workbooks[0].name == "Lectures")
        #expect(reloaded.workbooks[0].items.map(\.path) == ["/tmp/notes.pdf"])
    }

    @Test func restoresActiveWorkbookFromDefaults() {
        let (store, dir, _) = makeStore()
        let workbook = store.createWorkbook(named: "Lectures")
        store.saveNow()

        let defaults = UserDefaults(suiteName: "PDFViewerTests-\(UUID().uuidString)")!
        defaults.set(workbook.id.uuidString, forKey: "activeWorkbookID")

        let restored = WorkbookStore(defaults: defaults, storageDirectory: dir)
        #expect(restored.activeWorkbookID == workbook.id)
    }

    @Test func doesNotRestoreUnknownWorkbookID() {
        let (store, dir, _) = makeStore()
        let workbook = store.createWorkbook(named: "Lectures")
        store.saveNow()

        let defaults = UserDefaults(suiteName: "PDFViewerTests-\(UUID().uuidString)")!
        defaults.set(UUID().uuidString, forKey: "activeWorkbookID")

        let restored = WorkbookStore(defaults: defaults, storageDirectory: dir)
        #expect(restored.activeWorkbookID == nil)
        #expect(restored.workbooks.first?.id == workbook.id)
    }
}
