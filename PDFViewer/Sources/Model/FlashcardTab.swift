import Foundation

struct Flashcard: Identifiable {
    let id = UUID()
    let front: String
    let back: String
}

enum FlashcardRating {
    case know
    case stillLearning
    case dontKnow
}

/// A generated deck that opens as its own tab. The cards are also written to a
/// folder on disk (`deckURL`), so the deck outlives the tab.
///
/// Studying is a self-rated loop: cards stay in `queue` until they're marked
/// "I know", so unknown and still-learning cards come back around.
final class FlashcardTab: ObservableObject, Identifiable {
    let id = UUID()
    let title: String
    let cards: [Flashcard]
    let deckURL: URL?

    @Published private(set) var queue: [Flashcard]
    @Published private(set) var knownCount: Int = 0
    @Published var showingBack = false

    init(title: String, cards: [Flashcard], deckURL: URL?) {
        self.title = title
        self.cards = cards
        self.deckURL = deckURL
        self.queue = cards
    }

    var current: Flashcard? { queue.first }

    var isFinished: Bool { queue.isEmpty }

    var remainingCount: Int { queue.count }

    var totalCount: Int { cards.count }

    var progress: Double {
        totalCount == 0 ? 0 : Double(knownCount) / Double(totalCount)
    }

    func flip() {
        showingBack.toggle()
    }

    func rate(_ rating: FlashcardRating) {
        guard let card = queue.first else { return }
        queue.removeFirst()

        switch rating {
        case .know:
            knownCount += 1
        case .stillLearning:
            queue.insert(card, at: min(queue.count, 2))
        case .dontKnow:
            queue.insert(card, at: min(queue.count, 1))
        }

        showingBack = false
    }

    func shuffle() {
        queue.shuffle()
        showingBack = false
    }

    func restart() {
        queue = cards
        knownCount = 0
        showingBack = false
    }
}
