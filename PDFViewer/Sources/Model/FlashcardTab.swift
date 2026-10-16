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
    @Published var title: String
    let cards: [Flashcard]
    let deckURL: URL?

    @Published private(set) var queue: [Flashcard]
    @Published private(set) var knownCount: Int = 0
    @Published var index: Int = 0
    @Published var showingBack = false

    init(title: String, cards: [Flashcard], deckURL: URL?) {
        self.title = title
        self.cards = cards
        self.deckURL = deckURL
        self.queue = cards
    }

    var current: Flashcard? {
        queue.indices.contains(index) ? queue[index] : nil
    }

    var isFinished: Bool { queue.isEmpty }

    var remainingCount: Int { queue.count }

    var position: Int { queue.isEmpty ? 0 : index + 1 }

    var canGoNext: Bool { index < queue.count - 1 }

    var canGoPrevious: Bool { index > 0 }

    var totalCount: Int { cards.count }

    var progress: Double {
        totalCount == 0 ? 0 : Double(knownCount) / Double(totalCount)
    }

    func flip() {
        showingBack.toggle()
    }

    func next() {
        guard !queue.isEmpty else { return }
        index = min(index + 1, queue.count - 1)
        showingBack = false
    }

    func previous() {
        guard !queue.isEmpty else { return }
        index = max(index - 1, 0)
        showingBack = false
    }

    func rate(_ rating: FlashcardRating) {
        guard queue.indices.contains(index) else {
            index = 0
            return
        }

        let card = queue.remove(at: index)

        // Move to the following card before re-queueing, so rating the last
        // card doesn't immediately show it again.
        if index >= queue.count {
            index = max(0, queue.count - 1)
        }

        switch rating {
        case .know:
            knownCount += 1
        case .stillLearning:
            queue.insert(card, at: min(queue.count, index + 2))
        case .dontKnow:
            queue.insert(card, at: min(queue.count, index + 1))
        }

        showingBack = false
    }

    func shuffle() {
        queue.shuffle()
        index = 0
        showingBack = false
    }

    func restart() {
        queue = cards
        knownCount = 0
        index = 0
        showingBack = false
    }
}
