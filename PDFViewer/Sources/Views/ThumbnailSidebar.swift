import SwiftUI
import PDFKit

struct ThumbnailSidebar: NSViewRepresentable {
    @ObservedObject var tab: PDFDocumentTab

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = tab.pdfView
        view.thumbnailSize = CGSize(width: 96, height: 128)
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        if nsView.pdfView !== tab.pdfView {
            nsView.pdfView = tab.pdfView
        }
    }
}