import Foundation

enum QuizQuestionKind: String, Codable {
    case open
    case multipleChoice
}

struct QuizQuestion: Identifiable {
    let id = UUID()
    let prompt: String
    let answer: String
    let marks: Int
    let kind: QuizQuestionKind
    let options: [String]

    init(prompt: String, answer: String, marks: Int, kind: QuizQuestionKind = .open, options: [String] = []) {
        self.prompt = prompt
        self.answer = answer
        self.marks = marks
        self.kind = kind
        self.options = options
    }

    /// Index of the correct option (multiple-choice), matched from `answer`.
    var correctOptionIndex: Int? {
        guard kind == .multipleChoice else { return nil }
        return options.firstIndex {
            $0.caseInsensitiveCompare(answer.trimmingCharacters(in: .whitespaces)) == .orderedSame
        }
    }
}

struct QuizResult {
    let questionID: UUID
    let correct: Bool
    let awarded: Int
    let feedback: String
}

/// A generated, persisted quiz that opens as its own tab. Holds the questions,
/// the reader's answers, and the per-question results once marked.
final class QuizTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published private(set) var questions: [QuizQuestion]
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

    /// Total marks of the questions that have been marked so far.
    var gradedTotalMarks: Int {
        questions
            .filter { question in results.contains { $0.questionID == question.id } }
            .reduce(0) { $0 + $1.marks }
    }

    var answeredCount: Int {
        answers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// Answered questions that haven't been marked yet.
    var pending: [(index: Int, question: QuizQuestion)] {
        questions.enumerated().compactMap { offset, question in
            let answered =
                answers.indices.contains(offset)
                && !answers[offset].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasResult = results.contains { $0.questionID == question.id }
            return answered && !hasResult ? (offset + 1, question) : nil
        }
    }

    var canMark: Bool {
        !isMarking && !pending.isEmpty
    }

    func result(for question: QuizQuestion) -> QuizResult? {
        results.first { $0.questionID == question.id }
    }

    func removeQuestion(_ question: QuizQuestion) {
        guard let index = questions.firstIndex(where: { $0.id == question.id }) else { return }
        questions.remove(at: index)
        if answers.indices.contains(index) {
            answers.remove(at: index)
        }
        results.removeAll { $0.questionID == question.id }
        if results.isEmpty {
            marked = false
        }
    }

    func reset() {
        answers = Array(repeating: "", count: questions.count)
        results = []
        marked = false
    }
}
