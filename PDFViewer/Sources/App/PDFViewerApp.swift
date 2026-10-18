import SwiftUI
import UniformTypeIdentifiers

@main
struct PDFViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore.shared
    @StateObject private var agent = AgentChatModel.shared
    @StateObject private var workbooks = WorkbookStore.shared

    var body: some Scene {
        WindowGroup("PDF Viewer") {
            ContentView()
                .environmentObject(store)
                .environmentObject(agent)
                .environmentObject(workbooks)
                .onAppear {
                    // SwiftUI installs its own "Close" (Cmd+W) item that closes the window.
                    // We clear it once so our Cmd+W "Close Tab" item is the only Cmd+W.
                    MainMenuTweaks.apply()
                }
        }
        .defaultSize(width: 1240, height: 860)
        .windowToolbarStyle(.unified)
        .commands { appCommands }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        // "New" is useless here; keep "Open..." only.
        CommandGroup(replacing: .newItem) {
            Button("Open\u{2026}") {
                store.presentOpenPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandMenu("File") {
            Button("Close Tab") {
                store.closeSelectedTab()
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Reopen Closed Tab") {
                store.reopenClosedTab()
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!store.canReopenClosedTab)

            Divider()

            Menu("Open Flashcard Deck") {
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
                            Menu("Add to Workbook") {
                                ForEach(workbooks.workbooks) { workbook in
                                    Button(workbook.name) {
                                        workbooks.add(workbooks.makeItem(kind: .deck, title: deck.title, url: deck.url), to: workbook.id)
                                    }
                                }
                            }
                            .disabled(workbooks.workbooks.isEmpty)
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
            }

            Menu("Open Summary") {
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
                            Menu("Add to Workbook") {
                                ForEach(workbooks.workbooks) { workbook in
                                    Button(workbook.name) {
                                        workbooks.add(workbooks.makeItem(kind: .summary, title: summary.title, url: summary.url), to: workbook.id)
                                    }
                                }
                            }
                            .disabled(workbooks.workbooks.isEmpty)
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
            }

            Menu("Open Quiz") {
                if agent.savedQuizzes.isEmpty {
                    Button("No saved quizzes") {}
                        .disabled(true)
                } else {
                    ForEach(agent.savedQuizzes) { quiz in
                        Menu(quiz.title) {
                            Button("Open") {
                                agent.openSavedQuiz(quiz)
                            }
                            Divider()
                            Menu("Add to Workbook") {
                                ForEach(workbooks.workbooks) { workbook in
                                    Button(workbook.name) {
                                        workbooks.add(workbooks.makeItem(kind: .quiz, title: quiz.title, url: quiz.url), to: workbook.id)
                                    }
                                }
                            }
                            .disabled(workbooks.workbooks.isEmpty)
                            Button("Rename…") {
                                agent.promptRenameSavedQuiz(quiz)
                            }
                            Button("Delete…") {
                                agent.confirmDeleteSavedQuiz(quiz)
                            }
                        }
                    }
                }

                Divider()

                Button("Refresh List") {
                    agent.refreshSavedQuizzes()
                }
            }

            Divider()

            Button("New Note") {
                store.newNote()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Menu("Open Note") {
                let savedNotes = NotesStore.list()
                if savedNotes.isEmpty {
                    Button("No saved notes") {}
                        .disabled(true)
                } else {
                    ForEach(savedNotes, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            store.openNote(at: url)
                        }
                    }
                }
            }
        }

        CommandMenu("View") {
            Button("Find\u{2026}") {
                store.beginFind()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Divider()

            Button(store.showThumbnails ? "Hide Thumbnails" : "Show Thumbnails") {
                store.toggleThumbnails()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])

            Button(store.showAgentPanel ? "Hide Agent Panel" : "Show Agent Panel") {
                store.toggleAgentPanel()
            }
            .keyboardShortcut("a", modifiers: [.command, .option])

            Button(store.showAnnotations ? "Hide Notes" : "Show Notes") {
                store.toggleAnnotations()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
            .disabled(store.selectedTab == nil)

            Button(store.showLibrary ? "Hide Library" : "Show Library") {
                store.toggleLibrary()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])

            Button(store.showWorkbookChat ? "Hide Workbook Assistant" : "Show Workbook Assistant") {
                store.toggleWorkbookChat()
            }
            .keyboardShortcut("k", modifiers: [.command, .option])

            Button(TodoWindowController.shared.isVisible ? "Hide Tasks" : "Show Tasks") {
                TodoWindowController.shared.toggle()
            }

            Divider()

            Button("Zoom In") {
                store.zoomIn()
            }
            .keyboardShortcut("+", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Zoom Out") {
                store.zoomOut()
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Actual Size") {
                store.actualSize()
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(store.selectedTab == nil)

            Button("Fit to Width") {
                store.fitToWidth()
            }
            .disabled(store.selectedTab == nil)

            Divider()

            Button("Next Tab") {
                store.selectAdjacentTab(offset: 1)
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(store.tabs.count < 2)

            Button("Previous Tab") {
                store.selectAdjacentTab(offset: -1)
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(store.tabs.count < 2)
        }
    }
}