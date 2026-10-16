import SwiftUI
import PDFKit

struct PDFViewerPane: View {
    @ObservedObject var tab: PDFDocumentTab
    @EnvironmentObject private var store: LibraryStore
    var isFocused: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            if store.showThumbnails && isFocused {
                ThumbnailSidebar(tab: tab)
                    .frame(width: 172)
                    .id("sidebar")
                Divider().id("sidebar-divider")
            }

            VStack(spacing: 0) {
                PDFKitView(tab: tab)
                    .id("pdf-view")

                if store.isFindBarVisible(for: tab) {
                    FindBar(tab: tab, onClose: { store.endFind() })
                        .frame(height: 42)
                        .id("find-bar")
                }
            }
            .id("pane-main")
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear {
            tab.pdfView.layoutDocumentView()
            tab.finishRestoringIfNeeded()
        }
    }
}

/// Bridges the tab's already-configured `PDFView` into SwiftUI. Returning the
/// same instance every time is what keeps scroll position between tab switches.
struct PDFKitView: NSViewRepresentable {
    @ObservedObject var tab: PDFDocumentTab

    func makeNSView(context: Context) -> FitWidthPDFView {
        let view = tab.pdfView
        view.document = tab.document
        return view
    }

    func updateNSView(_ nsView: FitWidthPDFView, context: Context) {}
}