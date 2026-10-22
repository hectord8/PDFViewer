import Foundation
import Testing
#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct WorkbookTests {
    private func item(_ path: String) -> WorkbookItem {
        WorkbookItem(kind: .pdf, title: URL(fileURLWithPath: path).lastPathComponent, path: path)
    }

    @Test func containsPathChecksTopLevelItems() {
        let workbook = Workbook(name: "Term 1", items: [item("/tmp/lecture.pdf")])

        #expect(workbook.containsPath("/tmp/lecture.pdf"))
        #expect(!workbook.containsPath("/tmp/missing.pdf"))
    }

    @Test func containsPathSearchesNestedFolders() {
        let nested = WorkbookFolder(
            name: "Week 1",
            items: [item("/tmp/notes.pdf")],
            folders: [WorkbookFolder(name: "Day 2", items: [item("/tmp/slides.pdf")])]
        )
        let workbook = Workbook(name: "Term 1", folders: [nested])

        #expect(workbook.containsPath("/tmp/notes.pdf"))
        #expect(workbook.containsPath("/tmp/slides.pdf"))
        #expect(!workbook.containsPath("/tmp/lecture.pdf"))
    }

    @Test func folderContainsPathChecksItselfAndChildren() {
        let folder = WorkbookFolder(
            name: "Parent",
            items: [item("/tmp/a.pdf")],
            folders: [WorkbookFolder(name: "Child", items: [item("/tmp/b.pdf")])]
        )

        #expect(folder.containsPath("/tmp/a.pdf"))
        #expect(folder.containsPath("/tmp/b.pdf"))
        #expect(!folder.containsPath("/tmp/c.pdf"))
    }

    @Test func workbookRoundTripsThroughCodable() throws {
        let workbook = Workbook(
            name: "Term 1",
            items: [item("/tmp/lecture.pdf")],
            folders: [WorkbookFolder(name: "Week 1", items: [item("/tmp/notes.pdf")])]
        )

        let data = try JSONEncoder().encode(workbook)
        let decoded = try JSONDecoder().decode(Workbook.self, from: data)

        #expect(decoded.id == workbook.id)
        #expect(decoded.name == workbook.name)
        #expect(decoded.items.map(\.path) == workbook.items.map(\.path))
        #expect(decoded.folders.map(\.id) == workbook.folders.map(\.id))
        #expect(decoded.containsPath("/tmp/notes.pdf"))
    }

    @Test func folderRoundTripsThroughCodable() throws {
        let folder = WorkbookFolder(name: "Week 1", items: [item("/tmp/notes.pdf")])

        let data = try JSONEncoder().encode(folder)
        let decoded = try JSONDecoder().decode(WorkbookFolder.self, from: data)

        #expect(decoded.id == folder.id)
        #expect(decoded.name == folder.name)
        #expect(decoded.items.map(\.path) == ["/tmp/notes.pdf"])
        #expect(decoded.folders.isEmpty)
    }

    @Test func decodingWithoutOptionalFieldsUsesDefaults() throws {
        let workbookData = Data(#"{"name":"Term 1"}"#.utf8)
        let workbook = try JSONDecoder().decode(Workbook.self, from: workbookData)

        #expect(workbook.name == "Term 1")
        #expect(workbook.items.isEmpty)
        #expect(workbook.folders.isEmpty)
        #expect(workbook.containsPath("/tmp/nope.pdf") == false)

        let folderData = Data(#"{"name":"Week 1"}"#.utf8)
        let folder = try JSONDecoder().decode(WorkbookFolder.self, from: folderData)

        #expect(folder.name == "Week 1")
        #expect(folder.items.isEmpty)
        #expect(folder.folders.isEmpty)
    }
}
