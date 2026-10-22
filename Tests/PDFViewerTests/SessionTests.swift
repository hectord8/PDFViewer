import Foundation
import Testing
#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct SessionTests {
    @Test func sessionRoundTripsThroughCodable() throws {
        let session = Session(
            showThumbnails: true,
            selectedPath: "/tmp/a.pdf",
            secondaryPath: "/tmp/b.pdf",
            secondaryBookmark: Data([1, 2, 3]),
            focusedPane: .secondary,
            splitFraction: 0.25,
            pinnedPaths: ["/tmp/a.pdf"],
            tabs: [
                TabState(
                    path: "/tmp/a.pdf",
                    bookmark: Data([4, 5]),
                    pageIndex: 3,
                    zoomMode: .fitWidth,
                    scale: 1.5
                )
            ]
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        #expect(decoded.showThumbnails == session.showThumbnails)
        #expect(decoded.selectedPath == session.selectedPath)
        #expect(decoded.secondaryPath == session.secondaryPath)
        #expect(decoded.secondaryBookmark == session.secondaryBookmark)
        #expect(decoded.focusedPane == .secondary)
        #expect(decoded.splitFraction == 0.25)
        #expect(decoded.pinnedPaths == ["/tmp/a.pdf"])
        #expect(decoded.tabs.count == 1)
        #expect(decoded.tabs[0].path == "/tmp/a.pdf")
        #expect(decoded.tabs[0].bookmark == Data([4, 5]))
        #expect(decoded.tabs[0].pageIndex == 3)
        #expect(decoded.tabs[0].zoomMode == .fitWidth)
        #expect(decoded.tabs[0].scale == 1.5)
    }

    @Test func sessionDecodesWithoutOptionalFields() throws {
        let json = #"{"showThumbnails":false,"tabs":[]}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))

        #expect(!session.showThumbnails)
        #expect(session.selectedPath == nil)
        #expect(session.secondaryPath == nil)
        #expect(session.secondaryBookmark == nil)
        #expect(session.focusedPane == nil)
        #expect(session.splitFraction == nil)
        #expect(session.pinnedPaths == nil)
        #expect(session.tabs.isEmpty)
    }

    @Test func zoomAndPaneRawValuesAreStable() {
        #expect(ZoomMode.manual.rawValue == "manual")
        #expect(ZoomMode.fitWidth.rawValue == "fitWidth")
        #expect(Pane.primary.rawValue == "primary")
        #expect(Pane.secondary.rawValue == "secondary")
    }
}
