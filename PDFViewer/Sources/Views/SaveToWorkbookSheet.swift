import SwiftUI

/// Lets the user choose a workbook and folder for a note or transcript.
struct SaveToWorkbookSheet: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var workbooks: WorkbookStore
    @Environment(\.dismiss) private var dismiss

    let title: String
    let onSave: (UUID, UUID?) -> Void

    @State private var selectedWorkbookID: UUID?
    @State private var selectedFolderID: UUID?

    private struct FolderChoice: Identifiable {
        let id: UUID?
        let label: String
    }

    private var selectedWorkbook: Workbook? {
        guard let selectedWorkbookID else { return nil }
        return workbooks.workbooks.first { $0.id == selectedWorkbookID }
    }

    private var folderChoices: [FolderChoice] {
        var choices = [FolderChoice(id: nil, label: "Workbook root")]
        guard let workbook = selectedWorkbook else { return choices }

        func walk(_ folders: [WorkbookFolder], prefix: String) {
            for folder in folders {
                let label = prefix.isEmpty ? folder.name : "\(prefix) / \(folder.name)"
                choices.append(FolderChoice(id: folder.id, label: label))
                walk(folder.folders, prefix: label)
            }
        }
        walk(workbook.folders, prefix: "")
        return choices
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save to Workbook")
                .font(.headline)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if workbooks.workbooks.isEmpty {
                Text("Create a workbook in the Library first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Workbook", selection: $selectedWorkbookID) {
                    ForEach(workbooks.workbooks) { workbook in
                        Text(workbook.name).tag(Optional(workbook.id))
                    }
                }

                Picker("Folder", selection: $selectedFolderID) {
                    ForEach(folderChoices) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let workbookID = selectedWorkbookID else { return }
                    onSave(workbookID, selectedFolderID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedWorkbookID == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            selectedWorkbookID = workbooks.activeWorkbookID ?? workbooks.workbooks.first?.id
            selectedFolderID = nil
        }
        .onChange(of: selectedWorkbookID) { _, _ in
            selectedFolderID = nil
        }
        .hotReload()
    }
}
