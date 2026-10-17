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
                    ForEach(openEntries, id: \.item.id) { entry in
                        button(for: entry)
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
                    close: { store.closeTab(tab) }
                ))
            case .summary:
                guard let summary = store.summaries.first(where: { $0.fileURL?.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.selectedSummaryID == summary.id,
                    select: { store.selectSummary(summary) },
                    close: { store.closeSummary(summary) }
                ))
            case .deck:
                guard let deck = store.flashcards.first(where: { $0.deckURL?.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.selectedFlashcardID == deck.id,
                    select: { store.selectFlashcard(deck) },
                    close: { store.closeFlashcard(deck) }
                ))
            case .quiz:
                guard let quiz = store.quizzes.first(where: { $0.fileURL?.path == item.path }) else { return }
                result.append(Entry(
                    item: item,
                    folder: folder,
                    isActive: store.selectedQuizID == quiz.id,
                    select: { store.selectQuiz(quiz) },
                    close: { store.closeQuiz(quiz) }
                ))
            }
        }

        for folder in workbook.folders {
            for item in folder.items {
                consider(item, folder: folder.name)
            }
        }
        for item in workbook.items {
            consider(item, folder: nil)
        }
        return result
    }

    private func button(for entry: Entry) -> some View {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(entry.isActive ? Color(nsColor: .controlBackgroundColor) : .clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(entry.isActive ? 0.10 : 0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(entry.item.path)
        .contextMenu {
            Button("Close Tab") {
                entry.close()
            }
        }
    }

    private func icon(_ kind: WorkbookItemKind) -> String {
        switch kind {
        case .pdf: return "doc.text"
        case .summary: return "doc.plaintext"
        case .deck: return "rectangle.on.rectangle"
        case .quiz: return "checklist"
        }
    }
}
