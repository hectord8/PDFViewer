import AppKit
import PDFKit
import SwiftUI

/// The vertical position/size of a PDF page inside the owning `PDFView`, in
/// top-left (SwiftUI) coordinates, refreshed as the document scrolls or zooms.
struct PDFPageFrame: Identifiable, Equatable {
    let id: Int
    let top: CGFloat
    let height: CGFloat
}

/// Watches a tab's `PDFView` and publishes where each page currently sits.
@MainActor
final class PageGeometry: ObservableObject {
    @Published private(set) var frames: [PDFPageFrame] = []
    @Published private(set) var viewportHeight: CGFloat = 0

    private weak var pdfView: PDFView?
    private var scrollObserver: NSObjectProtocol?
    private var frameObserver: NSObjectProtocol?

    func attach(_ pdfView: PDFView) {
        detach()
        self.pdfView = pdfView

        if let scrollView = Self.scrollView(in: pdfView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }

        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        refresh()
    }

    func detach() {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        scrollObserver = nil
        frameObserver = nil
    }

    func refresh() {
        guard let pdfView, let document = pdfView.document else {
            frames = []
            viewportHeight = 0
            return
        }

        let height = pdfView.bounds.height
        viewportHeight = height
        let flipped = pdfView.isFlipped
        let margin: CGFloat = 500

        var result: [PDFPageFrame] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
            let top = flipped ? rect.minY : (height - rect.maxY)
            if top > height + margin || top + rect.height < -margin { continue }
            result.append(PDFPageFrame(id: index, top: top, height: rect.height))
        }
        frames = result
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? NSScrollView { return scrollView }
        }
        return nil
    }
}

/// A column of per-page notes that sits beside the PDF and scrolls with it:
/// each note is a box aligned to the vertical position of its page.
struct PageNotesPanel: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var agent: AgentChatModel
    @ObservedObject var tab: PDFDocumentTab
    @StateObject private var geometry = PageGeometry()
    @State private var editingPages: Set<Int> = []

    private let width: CGFloat = 260

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if tab.pageNotes.isEmpty {
                    emptyState
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ForEach(geometry.frames) { frame in
                        if let note = tab.pageNotes[frame.id] {
                            noteBox(page: frame.id, note: note)
                                .frame(width: max(geo.size.width - 16, 1), height: max(frame.height, 40))
                                .offset(y: frame.top)
                                .padding(.horizontal, 8)
                        }
                    }
                }

                if tab.isAnnotatingPages {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Writing notes…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear { geometry.attach(tab.pdfView) }
        .onDisappear { geometry.detach() }
    }

    private func noteBox(page: Int, note: String) -> some View {
        let isEditing = editingPages.contains(page)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Page \(page + 1)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    if isEditing {
                        editingPages.remove(page)
                    } else {
                        editingPages.insert(page)
                    }
                } label: {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isEditing ? "Done editing" : "Edit these notes")
            }

            if isEditing {
                TextEditor(text: noteBinding(page: page))
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MarkdownText(text: note)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    private func noteBinding(page: Int) -> Binding<String> {
        Binding(
            get: { tab.pageNotes[page] ?? "" },
            set: { tab.pageNotes[page] = $0 }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)

            Text("Notes for each page appear here, beside the page.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                store.showAnnotations = true
                Task { await agent.annotatePages(tab) }
            } label: {
                Label("Annotate", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(tab.isAnnotatingPages || !agent.status.isConnected)
        }
        .padding(24)
    }
}
