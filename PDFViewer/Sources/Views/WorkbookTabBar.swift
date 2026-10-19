import SwiftUI

/// A secondary tab strip for the active workbook, showing only the workbook's
/// files that are currently open. Clicking a tab focuses its existing tab.
struct WorkbookTabBar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workbooks: WorkbookStore

    let workbook: Workbook

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(workbook.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                Divider().frame(height: 16)

                if openEntries.isEmpty {
                    Text("No files from this workbook are open")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(openEntries.enumerated()), id: \.element.item.id) { index, entry in
                        button(for: entry, index: index)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .trailing) {
            Button {
                workbooks.activeWorkbookID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the workbook tabs")
        }
    }

    private struct Entry {
        let item: WorkbookItem
        let folder: String?
        let isActive: Bool
        let select: () -> Void
        let close: () -> Void
        let split: (() -> Void)?
        let reload: (() -> Void)?
        let duplicate: (() -> Void)?
    }

    private var openEntries: [Entry] {
        var result: [Entry] = []

        func consider(_ item: WorkbookItem, folder: String?) {
            switch item.kind {
            case .pdf:
                guard let tab = store.tabs.first(where: { $0.url.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.activeTab?.id == tab.id,
                    select: { store.select(tab) },
                    close: { store.closeTab(tab) },
                    split: { store.split(with: tab) },
                    reload: { store.reload(tab) },
                    duplicate: { store.duplicate(tab) }
                ))
            case .summary:
                guard let summary = store.summaries.first(where: { $0.fileURL?.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.selectedSummaryID == summary.id,
                    select: { store.selectSummary(summary) },
                    close: { store.closeSummary(summary) },
                    split: nil,
                    reload: nil,
                    duplicate: nil
                ))
            case .deck:
                guard let deck = store.flashcards.first(where: { $0.deckURL?.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.selectedFlashcardID == deck.id,
                    select: { store.selectFlashcard(deck) },
                    close: { store.closeFlashcard(deck) },
                    split: nil,
                    reload: nil,
                    duplicate: nil
                ))
            case .file:
                return
            case .note:
                guard let note = store.notes.first(where: { $0.fileURL?.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.selectedNoteID == note.id,
                    select: { store.selectNote(note) },
                    close: { store.closeNote(note) },
                    split: nil,
                    reload: nil,
                    duplicate: nil
                ))
            case .quiz:
                guard let quiz = store.quizzes.first(where: { $0.fileURL?.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.selectedQuizID == quiz.id,
                    select: { store.selectQuiz(quiz) },
                    close: { store.closeQuiz(quiz) },
                    split: nil,
                    reload: nil,
                    duplicate: nil
                ))
            }
        }

        func walk(_ folders: [WorkbookFolder], items: [WorkbookItem], folderName: String?) {
            for folder in folders {
                walk(folder.folders, items: folder.items, folderName: folder.name)
            }
            for item in items {
                consider(item, folder: folderName)
            }
        }

        walk(workbook.folders, items: workbook.items, folderName: nil)
        return result
    }

    private func button(for entry: Entry, index: Int) -> some View {
        Button {
            entry.select()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon(entry.item.kind))
                    .font(.system(size: 10))
                    .foregroundStyle(entry.isActive ? Color.accentColor : .secondary)

                if let folder = entry.folder {
                    Text(folder + " /")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Text(entry.item.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(entry.isActive ? Color.primary : .secondary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 20)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(entry.isActive ? Color(nsColor: .controlBackgroundColor) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(entry.isActive ? 0.10 : 0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help(entry.item.path)
        .contextMenu {
            if let split = entry.split {
                Button("Open in Split View") {
                    split()
                }
            }
            if store.isSplit {
                Button("Close Split View") {
                    store.collapseSplit()
                }
            }

            if let reload = entry.reload {
                Button("Reload") { reload() }
            }
            if let duplicate = entry.duplicate {
                Button("Duplicate") { duplicate() }
            }

            Divider()

            Button("Close Tab") {
                entry.close()
            }
            Button("Close Other Tabs") {
                closeOthers(keeping: entry)
            }
            .disabled(openEntries.count <= 1)
            Button("Close Tabs to the Right") {
                closeToRight(of: index)
            }
            .disabled(index >= openEntries.count - 1)
            Button("Reopen Closed Tab") {
                store.reopenClosedTab()
            }
            .disabled(!store.canReopenClosedTab)
        }
        .overlay(alignment: .trailing) {
            Button {
                entry.close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(entry.isActive ? 1 : 0.55))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 3)
            .help("Close this tab")
        }
    }

    private func closeOthers(keeping entry: Entry) {
        openEntries.filter { $0.item.id != entry.item.id }.forEach { $0.close() }
    }

    private func closeToRight(of index: Int) {
        guard index + 1 < openEntries.count else { return }
        openEntries[(index + 1)...].forEach { $0.close() }
    }

    private func icon(_ kind: WorkbookItemKind) -> String {
        switch kind {
        case .pdf: return "doc.text"
        case .summary: return "doc.plaintext"
        case .deck: return "rectangle.on.rectangle"
        case .quiz: return "checklist"
        case .note: return "note.text"
        case .file: return "doc"
        }
    }
}
