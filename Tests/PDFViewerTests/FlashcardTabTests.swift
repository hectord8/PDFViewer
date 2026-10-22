import Foundation
import Testing
#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct FlashcardTabTests {
    private func card(_ front: String) -> Flashcard {
        Flashcard(front: front, back: "\(front) back")
    }

    private func tab(_ fronts: [String]) -> FlashcardTab {
        FlashcardTab(title: "Deck", cards: fronts.map(card), deckURL: nil)
    }

    @Test func startsAtFirstCard() {
        let deck = tab(["A", "B", "C"])

        #expect(deck.current?.front == "A")
        #expect(deck.index == 0)
        #expect(deck.position == 1)
        #expect(deck.totalCount == 3)
        #expect(deck.remainingCount == 3)
        #expect(deck.knownCount == 0)
        #expect(deck.progress == 0)
        #expect(!deck.isFinished)
        #expect(deck.canGoNext)
        #expect(!deck.canGoPrevious)
    }

    @Test func navigationClampsAtBothEnds() {
        let deck = tab(["A", "B"])

        deck.next()
        #expect(deck.index == 1)
        #expect(!deck.canGoNext)

        deck.next()
        #expect(deck.index == 1)

        deck.previous()
        #expect(deck.index == 0)

        deck.previous()
        #expect(deck.index == 0)
    }

    @Test func navigationResetsFlip() {
        let deck = tab(["A", "B"])
        deck.flip()
        #expect(deck.showingBack)

        deck.next()
        #expect(!deck.showingBack)
    }

    @Test func emptyDeckHasNoCurrentCard() {
        let deck = tab([])

        #expect(deck.current == nil)
        #expect(deck.isFinished)
        #expect(deck.position == 0)
        #expect(deck.progress == 0)

        deck.next()
        deck.previous()
        #expect(deck.index == 0)
    }

    @Test func flippingTogglesShowingBack() {
        let deck = tab(["A"])

        deck.flip()
        #expect(deck.showingBack)

        deck.flip()
        #expect(!deck.showingBack)
    }

    @Test func knowingCardRemovesItFromQueue() {
        let deck = tab(["A", "B", "C"])

        deck.rate(.know)

        #expect(deck.knownCount == 1)
        #expect(deck.remainingCount == 2)
        #expect(deck.queue.map(\.front) == ["B", "C"])
        #expect(deck.current?.front == "B")
        #expect(deck.progress == 1.0 / 3.0)
    }

    @Test func lastKnownCardClampsIndex() {
        let deck = tab(["A", "B"])
        deck.next()
        #expect(deck.index == 1)

        deck.rate(.know)

        #expect(deck.knownCount == 1)
        #expect(deck.queue.map(\.front) == ["A"])
        #expect(deck.index == 0)
        #expect(deck.current?.front == "A")
    }

    @Test func dontKnowRequeuesCardRightAfterCurrent() {
        let deck = tab(["A", "B", "C"])

        deck.rate(.dontKnow)

        #expect(deck.knownCount == 0)
        #expect(deck.queue.map(\.front) == ["B", "A", "C"])
        #expect(deck.current?.front == "B")
    }

    @Test func stillLearningRequeuesCardFurtherBack() {
        let deck = tab(["A", "B", "C"])

        deck.rate(.stillLearning)

        #expect(deck.knownCount == 0)
        #expect(deck.queue.map(\.front) == ["B", "C", "A"])
        #expect(deck.current?.front == "B")
    }

    @Test func ratingEmptyDeckResetsIndexSafely() {
        let deck = tab([])

        deck.rate(.know)

        #expect(deck.index == 0)
        #expect(deck.isFinished)
        #expect(deck.knownCount == 0)
    }

    @Test func finishingTheQueueReportsFinished() {
        let deck = tab(["A"])

        deck.rate(.know)

        #expect(deck.isFinished)
        #expect(deck.remainingCount == 0)
        #expect(deck.position == 0)
        #expect(deck.progress == 1)
    }

    @Test func restartRestoresOriginalDeck() {
        let deck = tab(["A", "B"])
        deck.rate(.know)
        deck.next()

        deck.restart()

        #expect(deck.queue.map(\.front) == ["A", "B"])
        #expect(deck.knownCount == 0)
        #expect(deck.index == 0)
        #expect(!deck.showingBack)
    }

    @Test func shuffleKeepsCardsAndResetsPosition() {
        let deck = tab(["A", "B", "C", "D"])
        deck.next()
        deck.next()
        deck.flip()

        deck.shuffle()

        #expect(deck.index == 0)
        #expect(!deck.showingBack)
        #expect(Set(deck.queue.map(\.front)) == Set(["A", "B", "C", "D"]))
    }
}
