import SwiftUI

struct DocumentTabBar: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workbooks: WorkbookStore

    /// Paths of files in any workbook. While a workbook is active those files
    /// live in its workbook tab strip; other workbooks' open files stay parked
    /// until that workbook is entered again.
    private var hiddenWorkbookPaths: Set<String> {
        guard workbooks.activeWorkbookID != nil else { return [] }
        return workbooks.workbooks.reduce(into: Set<String>()) { paths, workbook in
            paths.formUnion(workbook.allPaths)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.bar).frame(height: 6)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tabs.filter { !hiddenWorkbookPaths.contains($0.url.path) }) { tab in
                            if store.isPinned(tab) {
                                pinnedTabButton(for: tab)
                                    .id(tab.id)
                            } else {
                                tabButton(for: tab)
                                    .id(tab.id)
                            }
                        }

                        ForEach(store.quizzes.filter { !hiddenWorkbookPaths.contains($0.fileURL?.path ?? "") }) {
                            quiz in
                            quizTabButton(for: quiz)
                                .id(quiz.id)
                        }

                        ForEach(store.flashcards.filter { !hiddenWorkbookPaths.contains($0.deckURL?.path ?? "") }) {
                            deck in
                            flashcardTabButton(for: deck)
                                .id(deck.id)
                        }

                        ForEach(store.summaries.filter { !hiddenWorkbookPaths.contains($0.fileURL?.path ?? "") }) {
                            summary in
                            summaryTabButton(for: summary)
                                .id(summary.id)
                        }

                        ForEach(store.notes.filter { !hiddenWorkbookPaths.contains($0.fileURL?.path ?? "") }) { note in
                            noteTabButton(for: note)
                                .id(note.id)
                        }

                        ForEach(store.lectureTabs) { lecture in
                            lectureTabButton(for: lecture)
                                .id(lecture.id)
                        }

                        Button {
                            store.presentOpenPanel()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .help("Open another PDF")
                        .padding(.leading, 2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onChange(of: store.selectedTabID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
                .onChange(of: store.selectedQuizID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
                .onChange(of: store.selectedFlashcardID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
                .onChange(of: store.selectedSummaryID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
                .onChange(of: store.selectedNoteID) { _, newValue in
                    guard let newValue else { return }
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
        .frame(height: 42)
        .background(.bar)
        .contextMenu {
            Button("New Tab") {
                store.presentOpenPanel()
            }
            Button("Reopen Closed Tab") {
                store.reopenClosedTab()
            }
            .disabled(!store.canReopenClosedTab)
        }
        .hotReload()
    }

    private func tabButton(for tab: PDFDocumentTab) -> some View {
        let isPrimary = store.selectedTabID == tab.id
        let isSecondary = store.secondaryTabID == tab.id
        let isPaneTab = isPrimary || isSecondary
        let isFocusedTab =
            (isPrimary && store.focusedPane == .primary)
            || (isSecondary && store.focusedPane == .secondary)

        let background: Color =
            isFocusedTab
            ? Color(nsColor: .controlBackgroundColor)
            : (isPaneTab ? Color(nsColor: .controlBackgroundColor).opacity(0.5) : .clear)

        return Button {
            store.select(tab)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocusedTab ? Color.accentColor : .secondary)

                Text(tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .foregroundStyle(isFocusedTab ? Color.primary : .secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 26)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                if isFocusedTab {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .padding(.horizontal, 10)
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help(tab.url.path)
        .contextMenu { tabMenu(for: tab) }
        .overlay(alignment: .trailing) {
            Button {
                store.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(isFocusedTab ? 1 : 0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help("Close this tab")
        }
    }

    private func pinnedTabButton(for tab: PDFDocumentTab) -> some View {
        let isFocusedTab =
            store.selectedTabID == tab.id && store.focusedPane == .primary
            || store.secondaryTabID == tab.id && store.focusedPane == .secondary

        return Button {
            store.select(tab)
        } label: {
            Image(systemName: "doc.text")
                .font(.system(size: 11))
                .foregroundStyle(isFocusedTab ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help(tab.title)
        .contextMenu { tabMenu(for: tab) }
    }

    private func quizTabButton(for quiz: QuizTab) -> some View {
        let isFocusedTab = store.selectedQuizID == quiz.id

        return Button {
            store.selectQuiz(quiz)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocusedTab ? Color.accentColor : .secondary)

                Text(quiz.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .foregroundStyle(isFocusedTab ? Color.primary : .secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 26)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                if isFocusedTab {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .padding(.horizontal, 10)
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help(quiz.title)
        .contextMenu {
            Button("Close Tab") {
                store.closeQuiz(quiz)
            }
        }
        .overlay(alignment: .trailing) {
            Button {
                store.closeQuiz(quiz)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(isFocusedTab ? 1 : 0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help("Close this tab")
        }
    }

    private func flashcardTabButton(for deck: FlashcardTab) -> some View {
        let isFocusedTab = store.selectedFlashcardID == deck.id

        return Button {
            store.selectFlashcard(deck)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocusedTab ? Color.accentColor : .secondary)

                Text(deck.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .foregroundStyle(isFocusedTab ? Color.primary : .secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 26)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                if isFocusedTab {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .padding(.horizontal, 10)
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help(deck.deckURL?.path ?? deck.title)
        .contextMenu {
            Button("Close Tab") {
                store.closeFlashcard(deck)
            }
        }
        .overlay(alignment: .trailing) {
            Button {
                store.closeFlashcard(deck)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(isFocusedTab ? 1 : 0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help("Close this tab")
        }
    }

    private func summaryTabButton(for summary: SummaryTab) -> some View {
        let isFocusedTab = store.selectedSummaryID == summary.id

        return Button {
            store.selectSummary(summary)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocusedTab ? Color.accentColor : .secondary)

                Text(summary.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .foregroundStyle(isFocusedTab ? Color.primary : .secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 26)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                if isFocusedTab {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .padding(.horizontal, 10)
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help(summary.fileURL?.path ?? summary.title)
        .contextMenu {
            Button("Close Tab") {
                store.closeSummary(summary)
            }
        }
        .overlay(alignment: .trailing) {
            Button {
                store.closeSummary(summary)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(isFocusedTab ? 1 : 0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help("Close this tab")
        }
    }

    private func noteTabButton(for note: NoteTab) -> some View {
        let isFocusedTab = store.selectedNoteID == note.id

        return Button {
            store.selectNote(note)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocusedTab ? Color.accentColor : .secondary)

                Text(note.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .foregroundStyle(isFocusedTab ? Color.primary : .secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 26)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                if isFocusedTab {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .padding(.horizontal, 10)
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help(note.fileURL?.path ?? note.title)
        .contextMenu {
            if store.selectedTab != nil {
                Button("Split with PDF") {
                    store.splitNoteWithPDF(note)
                }
            }
            Button("Close Tab") {
                store.closeNote(note)
            }
        }
        .overlay(alignment: .trailing) {
            Button {
                store.closeNote(note)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(isFocusedTab ? 1 : 0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help("Close this tab")
        }
    }

    private func lectureTabButton(for lecture: LectureTab) -> some View {
        let isFocusedTab = store.selectedLectureID == lecture.id

        return Button {
            store.selectLectureTab(lecture)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 11))
                    .foregroundStyle(isFocusedTab ? Color.accentColor : .secondary)

                Text(lecture.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                    .foregroundStyle(isFocusedTab ? Color.primary : .secondary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 26)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
            .overlay(alignment: .bottom) {
                if isFocusedTab {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(height: 2.5)
                        .padding(.horizontal, 10)
                        .offset(y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverTint()
        .help("Echo360 lecture portal")
        .contextMenu {
            Button("Close Tab") {
                store.closeLectureTab(lecture)
            }
        }
        .overlay(alignment: .trailing) {
            Button {
                store.closeLectureTab(lecture)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.secondary.opacity(isFocusedTab ? 1 : 0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
            .help("Close this tab")
        }
    }

    @ViewBuilder
    private func addToWorkbookMenu(item: WorkbookItem) -> some View {
        Menu("Add to Workbook") {
            if workbooks.workbooks.isEmpty {
                Button("No workbooks") {}
                    .disabled(true)
            } else {
                ForEach(workbooks.workbooks) { workbook in
                    Button(workbook.name) {
                        workbooks.add(item, to: workbook.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tabMenu(for tab: PDFDocumentTab) -> some View {
        let isPaneTab = store.selectedTabID == tab.id || store.secondaryTabID == tab.id

        Button("New Tab to the Right") {
            store.presentOpenPanel(after: tab)
        }

        Button("Reload") {
            store.reload(tab)
        }

        Button("Duplicate") {
            store.duplicate(tab)
        }

        addToWorkbookMenu(item: workbooks.makeItem(kind: .pdf, title: tab.title, url: tab.url))

        Button(store.isPinned(tab) ? "Unpin Tab" : "Pin Tab") {
            store.togglePin(tab)
        }

        if store.isSplit && isPaneTab {
            Divider()
            Button("Close Split View") {
                store.collapseSplit()
            }
        } else {
            Divider()
            Button("Open in Split View…") {
                store.split(with: tab)
            }
        }

        Divider()

        Button("Close Tab") {
            store.closeTab(tab)
        }

        Button("Close Other Tabs") {
            store.closeOtherTabs(keeping: tab)
        }
        .disabled(!store.canCloseOtherTabs(keeping: tab))

        Button("Close Tabs to the Right") {
            store.closeTabsToRight(of: tab)
        }
        .disabled(!store.canCloseTabsToRight(of: tab))
    }
}

/// Subtle hover highlight shared by the tab chips.
struct HoverTint: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverTint() -> some View {
        modifier(HoverTint())
    }
}
