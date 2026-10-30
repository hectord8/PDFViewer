import PDFKit
import SwiftUI

/// The sidebar beside the PDF: page thumbnails, plus the document's own table
/// of contents when it has one.
struct DocumentSidebar: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    enum Mode: String {
        case pages
        case contents
    }

    @ObservedObject var tab: PDFDocumentTab
    @AppStorage("documentSidebarMode") private var modeRaw = Mode.pages.rawValue

    private var mode: Mode {
        guard !tab.outline.isEmpty else { return .pages }
        return Mode(rawValue: modeRaw) ?? .pages
    }

    var body: some View {
        VStack(spacing: 0) {
            if !tab.outline.isEmpty {
                Picker("Sidebar", selection: $modeRaw) {
                    Text("Pages").tag(Mode.pages.rawValue)
                    Text("Contents").tag(Mode.contents.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(8)

                Divider()
            }

            switch mode {
            case .pages:
                ThumbnailSidebar(tab: tab)
            case .contents:
                OutlineSidebar(tab: tab)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .hotReload()
    }
}

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

/// The PDF's built-in outline (bookmarks / table of contents). The section
/// you're reading is highlighted and kept in view as you scroll.
struct OutlineSidebar: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @ObservedObject var tab: PDFDocumentTab

    var body: some View {
        let current = PDFOutlineNode.current(in: tab.outline, pageIndex: tab.pageIndex)

        ScrollViewReader { proxy in
            List {
                OutlineGroup(tab.outline, children: \.children) { node in
                    OutlineRow(node: node, isCurrent: node.id == current) {
                        tab.go(to: node)
                    }
                    .id(node.id)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onAppear {
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
            .onChange(of: current) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(newValue)
                }
            }
        }
        .hotReload()
    }
}

private struct OutlineRow: View {
    let node: PDFOutlineNode
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(node.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let page = node.pageIndex {
                    Text("\(page + 1)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(node.pageIndex == nil && node.destination == nil)
        .help(node.pageIndex.map { "\(node.title) — page \($0 + 1)" } ?? node.title)
    }
}
