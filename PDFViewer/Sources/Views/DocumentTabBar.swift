import SwiftUI

struct DocumentTabBar: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var agent: AgentChatModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.bar).frame(height: 6)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.tabs) { tab in
                            if store.isPinned(tab) {
                                pinnedTabButton(for: tab)
                                    .id(tab.id)
                            } else {
                                tabButton(for: tab)
                                    .id(tab.id)
                            }
                        }

                        ForEach(store.quizzes) { quiz in
                            quizTabButton(for: quiz)
                                .id(quiz.id)
                        }

                        ForEach(store.flashcards) { deck in
                            flashcardTabButton(for: deck)
                                .id(deck.id)
                        }

                        ForEach(store.summaries) { summary in
                            summaryTabButton(for: summary)
                                .id(summary.id)
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

                        Menu {
                            if agent.savedDecks.isEmpty {
                                Button("No saved decks") {}
                                    .disabled(true)
                            } else {
                                ForEach(agent.savedDecks) { deck in
                                    Menu("\(deck.title) · \(deck.cardCount) cards") {
                                        Button("Open") {
                                            agent.openSavedDeck(deck)
                                        }
                                        Divider()
                                        Button("Rename…") {
                                            agent.promptRenameDeck(deck)
                                        }
                                        Button("Delete…") {
                                            agent.confirmDeleteDeck(deck)
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Refresh List") {
                                agent.refreshSavedDecks()
                            }
                        } label: {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Open a saved flashcard deck")

                        Menu {
                            if agent.savedSummaries.isEmpty {
                                Button("No saved summaries") {}
                                    .disabled(true)
                            } else {
                                ForEach(agent.savedSummaries) { summary in
                                    Menu(summary.title) {
                                        Button("Open") {
                                            agent.openSavedSummary(summary)
                                        }
                                        Divider()
                                        Button("Rename…") {
                                            agent.promptRenameSummary(summary)
                                        }
                                        Button("Delete…") {
                                            agent.confirmDeleteSummary(summary)
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button("Refresh List") {
                                agent.refreshSavedSummaries()
                            }
                        } label: {
                            Image(systemName: "doc.plaintext")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Open a saved summary")
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
    }

    private func tabButton(for tab: PDFDocumentTab) -> some View {
        let isPrimary = store.selectedTabID == tab.id
        let isSecondary = store.secondaryTabID == tab.id
        let isPaneTab = isPrimary || isSecondary
        let isFocusedTab = (isPrimary && store.focusedPane == .primary)
            || (isSecondary && store.focusedPane == .secondary)

        let background: Color = isFocusedTab
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
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
        let isFocusedTab = store.selectedTabID == tab.id && store.focusedPane == .primary
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
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isFocusedTab ? Color(nsColor: .controlBackgroundColor) : .clear)
                    .shadow(color: .black.opacity(isFocusedTab ? 0.18 : 0), radius: 1.5, y: 0.5)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFocusedTab ? 0.10 : 0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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

        Button(store.isPinned(tab) ? "Unpin Tab" : "Pin Tab") {
            store.togglePin(tab)
        }

        if store.isSplit && isPaneTab {
            Divider()
            Button("Close Split View") {
                store.collapseSplit()
            }
        } else if store.tabs.count > 1 {
            Divider()
            Button("Open in Split View") {
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
