import Foundation

struct QuizQuestion: Identifiable {
    let id = UUID()
    let prompt: String
    let answer: String
    let marks: Int
}

struct QuizResult {
    let index: Int
    let correct: Bool
    let awarded: Int
    let feedback: String
}

/// A generated, non-persisted quiz that opens as its own tab. Holds the
/// questions, the reader's answers, and — once marked — the per-question
/// results returned by opencode.
final class QuizTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    let questions: [QuizQuestion]
    @Published var fileURL: URL?

    @Published var answers: [String]
    @Published var results: [QuizResult] = []
    @Published var marked = false
    @Published var isMarking = false

    init(title: String, questions: [QuizQuestion], fileURL: URL? = nil) {
        self.title = title
        self.questions = questions
        self.fileURL = fileURL
        self.answers = Array(repeating: "", count: questions.count)
    }

    var totalMarks: Int {
        questions.reduce(0) { $0 + $1.marks }
    }

    var awardedMarks: Int {
        results.reduce(0) { $0 + $1.awarded }
    }

    var answeredCount: Int {
        answers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var canMark: Bool {
        !marked && !isMarking && answeredCount > 0
    }

    func result(forQuestionAt index: Int) -> QuizResult? {
        results.first { $0.index == index + 1 }
    }

    func reset() {
        answers = Array(repeating: "", count: questions.count)
        results = []
        marked = false
    }
}
