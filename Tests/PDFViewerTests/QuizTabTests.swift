import Foundation
import Testing
#if canImport(PDFViewer)
@testable import PDFViewer
#else
@testable import PDFViewerKit
#endif

struct QuizTabTests {
    private func question(
        _ prompt: String,
        answer: String,
        marks: Int,
        kind: QuizQuestionKind = .open,
        options: [String] = []
    ) -> QuizQuestion {
        QuizQuestion(prompt: prompt, answer: answer, marks: marks, kind: kind, options: options)
    }

    @Test func totalsMarks() {
        let quiz = QuizTab(title: "Quiz", questions: [
            question("A", answer: "a", marks: 2),
            question("B", answer: "b", marks: 3)
        ])

        #expect(quiz.totalMarks == 5)
        #expect(quiz.awardedMarks == 0)
        #expect(quiz.gradedTotalMarks == 0)
    }

    @Test func awardedAndGradedTotalsOnlyIncludeMarkedQuestions() {
        let first = question("A", answer: "a", marks: 2)
        let second = question("B", answer: "b", marks: 3)
        let quiz = QuizTab(title: "Quiz", questions: [first, second])
        quiz.results = [
            QuizResult(questionID: first.id, correct: true, awarded: 2, feedback: "")
        ]

        #expect(quiz.awardedMarks == 2)
        #expect(quiz.gradedTotalMarks == 2)
    }

    @Test func countsAnsweredQuestions() {
        let quiz = QuizTab(title: "Quiz", questions: [
            question("A", answer: "a", marks: 1),
            question("B", answer: "b", marks: 1),
            question("C", answer: "c", marks: 1)
        ])
        quiz.answers = ["yes", "   ", "no\n"]

        #expect(quiz.answeredCount == 2)
    }

    @Test func pendingIsAnsweredAndUnmarkedOnly() {
        let first = question("A", answer: "a", marks: 1)
        let second = question("B", answer: "b", marks: 1)
        let third = question("C", answer: "c", marks: 1)
        let quiz = QuizTab(title: "Quiz", questions: [first, second, third])
        quiz.answers = ["yes", "no", ""]
        quiz.results = [
            QuizResult(questionID: first.id, correct: true, awarded: 1, feedback: "")
        ]

        #expect(quiz.pending.map(\.index) == [2])
        #expect(quiz.pending.first?.question.id == second.id)
        #expect(quiz.canMark)
    }

    @Test func cannotMarkWhileMarkingOrWithNothingPending() {
        let quiz = QuizTab(title: "Quiz", questions: [
            question("A", answer: "a", marks: 1)
        ])

        #expect(!quiz.canMark)

        quiz.answers = ["yes"]
        #expect(quiz.canMark)

        quiz.isMarking = true
        #expect(!quiz.canMark)
    }

    @Test func correctOptionIndexMatchesTrimmedCaseInsensitiveAnswer() {
        let multipleChoice = question(
            "Capital of France?",
            answer: "  paris ",
            marks: 1,
            kind: .multipleChoice,
            options: ["London", "Paris", "Rome"]
        )

        #expect(multipleChoice.correctOptionIndex == 1)
    }

    @Test func correctOptionIndexIsNilForOpenQuestionsOrUnknownAnswers() {
        let open = question("Explain", answer: "anything", marks: 1)
        let unmatched = question(
            "Capital?",
            answer: "Berlin",
            marks: 1,
            kind: .multipleChoice,
            options: ["Paris", "Rome"]
        )

        #expect(open.correctOptionIndex == nil)
        #expect(unmatched.correctOptionIndex == nil)
    }

    @Test func removesQuestionAnswerAndResult() {
        let first = question("A", answer: "a", marks: 1)
        let second = question("B", answer: "b", marks: 1)
        let quiz = QuizTab(title: "Quiz", questions: [first, second])
        quiz.answers = ["one", "two"]
        quiz.results = [
            QuizResult(questionID: first.id, correct: true, awarded: 1, feedback: "")
        ]
        quiz.marked = true

        quiz.removeQuestion(first)

        #expect(quiz.questions.map(\.id) == [second.id])
        #expect(quiz.answers == ["two"])
        #expect(quiz.results.isEmpty)
        #expect(!quiz.marked)
    }

    @Test func removingUnknownQuestionDoesNothing() {
        let quiz = QuizTab(title: "Quiz", questions: [
            question("A", answer: "a", marks: 1)
        ])
        let stranger = question("B", answer: "b", marks: 1)

        quiz.removeQuestion(stranger)

        #expect(quiz.questions.count == 1)
        #expect(quiz.answers.count == 1)
    }

    @Test func resetClearsAnswersResultsAndMarkedState() {
        let quiz = QuizTab(title: "Quiz", questions: [
            question("A", answer: "a", marks: 1),
            question("B", answer: "b", marks: 1)
        ])
        quiz.answers = ["one", "two"]
        quiz.results = [
            QuizResult(questionID: quiz.questions[0].id, correct: true, awarded: 1, feedback: "")
        ]
        quiz.marked = true

        quiz.reset()

        #expect(quiz.answers == ["", ""])
        #expect(quiz.results.isEmpty)
        #expect(!quiz.marked)
    }
}
