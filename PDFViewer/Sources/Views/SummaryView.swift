import AppKit
import SwiftUI

struct SummaryView: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @ObservedObject var tab: SummaryTab
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                MathOrMarkdown(markdown: tab.text)
                    .padding(24)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .hotReload()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title)
                    .font(.title2.bold())

                if let url = tab.fileURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label(url.path, systemImage: "doc.text")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal the saved summary in Finder")
                }
            }

            Spacer()

            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(tab.text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .foregroundStyle(copied ? Color.green : Color.secondary)
            .disabled(tab.text.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
}
