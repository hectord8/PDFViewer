import Foundation

/// A generated summary that opens as its own tab. The text is also written to
/// disk (`fileURL`) as Markdown, so it can be reopened later.
final class SummaryTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var text: String
    @Published var fileURL: URL?

    init(title: String, text: String, fileURL: URL?) {
        self.title = title
        self.text = text
        self.fileURL = fileURL
    }
}
