import Testing
#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct AgentChatHeuristicsTests {
    @Test @MainActor func detectsQuizRequests() {
        #expect(AgentChatModel.looksLikeQuiz("Quiz me on chapter 1"))
        #expect(AgentChatModel.looksLikeQuiz("Can you test me on this?"))
        #expect(AgentChatModel.looksLikeQuiz("Give me some practice questions"))
    }

    @Test @MainActor func ignoresNonQuizRequests() {
        #expect(!AgentChatModel.looksLikeQuiz("Summarize this chapter"))
        #expect(!AgentChatModel.looksLikeQuiz("Open the folder"))
        #expect(!AgentChatModel.looksLikeQuiz(""))
    }

    @Test @MainActor func detectsFlashcardRequests() {
        #expect(AgentChatModel.looksLikeFlashcards("Make flashcards from these notes"))
        #expect(AgentChatModel.looksLikeFlashcards("Turn this into flash cards"))
        #expect(AgentChatModel.looksLikeFlashcards("Build me an Anki deck"))
        #expect(AgentChatModel.looksLikeFlashcards("I need some flip cards"))
    }

    @Test @MainActor func ignoresNonFlashcardRequests() {
        #expect(!AgentChatModel.looksLikeFlashcards("Make a summary"))
        #expect(!AgentChatModel.looksLikeFlashcards("Quiz me on this"))
        #expect(!AgentChatModel.looksLikeFlashcards(""))
    }
}
