import AppKit
import SwiftUI

struct LibrarySidebar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workbooks: WorkbookStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .foregroundStyle(.secondary)
            Text("Library")
                .font(.headline)

            Spacer()

            Button {
                createWorkbook()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("New workbook")

            Button {
                store.showLibrary = false
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.plain)
            .help("Hide the library")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    @ViewBuilder
    private var content: some View {
        if workbooks.workbooks.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Group your lectures, past papers and other resources into workbooks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    createWorkbook()
                } label: {
                    Label("New Workbook", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LibraryOutlineView(store: workbooks)
        }
    }

    private func createWorkbook() {
        let alert = NSAlert()
        alert.messageText = "New Workbook"
        alert.informativeText = "Name this workbook."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "Workbook"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        workbooks.createWorkbook(named: field.stringValue)
    }
}
