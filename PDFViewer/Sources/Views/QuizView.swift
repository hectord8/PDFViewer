import SwiftUI

struct QuizView: View {
    @EnvironmentObject private var agent: AgentChatModel
    @ObservedObject var tab: QuizTab

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(tab.questions.enumerated()), id: \.element.id) { index, question in
                        questionView(index: index, question: question)
                    }
                }
                .padding(24)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title)
                    .font(.title2.bold())
                Text("\(tab.questions.count) question\(tab.questions.count == 1 ? "" : "s") · \(tab.totalMarks) marks")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if tab.marked {
                Text("\(tab.awardedMarks) / \(tab.totalMarks)")
                    .font(.system(.largeTitle, design: .rounded).bold())
                    .monospacedDigit()
                    .foregroundStyle(scoreColor)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func questionView(index: Int, question: QuizQuestion) -> some View {
        let result = tab.result(forQuestionAt: index)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index + 1).")
                    .font(.headline)
                    .monospacedDigit()
                MathOrText(markdown: question.prompt, fontSize: 14)
                Spacer(minLength: 8)
                Text("\(question.marks) mark\(question.marks == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: binding(for: index))
                .font(.body)
                .frame(minHeight: 70)
                .padding(6)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(borderColor(result), lineWidth: 1)
                )
                .disabled(tab.marked)

            if tab.marked, let result {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result.correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.correct ? Color.green : Color.red)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.correct ? "Correct · +\(result.awarded)" : "Incorrect · +\(result.awarded)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(result.correct ? Color.green : Color.red)

                        if !result.feedback.isEmpty {
                            MathOrText(markdown: result.feedback, fontSize: 12)
                        }

                        if !question.answer.isEmpty {
                            MathOrText(markdown: "Model answer: \(question.answer)", fontSize: 12)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if tab.marked {
                Label("Marked", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retake") {
                    tab.reset()
                }
            } else {
                Text("\(tab.answeredCount) of \(tab.questions.count) answered")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await agent.mark(tab) }
                } label: {
                    if tab.isMarking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Marking…")
                        }
                    } else {
                        Text("Mark quiz")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tab.canMark)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func binding(for index: Int) -> Binding<String> {
        Binding(
            get: { tab.answers.indices.contains(index) ? tab.answers[index] : "" },
            set: { newValue in
                guard tab.answers.indices.contains(index) else { return }
                tab.answers[index] = newValue
            }
        )
    }

    private func borderColor(_ result: QuizResult?) -> Color {
        guard let result else { return Color.primary.opacity(0.12) }
        return (result.correct ? Color.green : Color.red).opacity(0.6)
    }

    private var scoreColor: Color {
        guard tab.totalMarks > 0 else { return .primary }
        let fraction = Double(tab.awardedMarks) / Double(tab.totalMarks)
        if fraction >= 0.8 { return .green }
        if fraction >= 0.5 { return .orange }
        return .red
    }
}
