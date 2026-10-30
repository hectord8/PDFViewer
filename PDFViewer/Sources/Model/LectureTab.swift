import Foundation

/// The main-window tab that hosts the Echo360 lecture portal.
final class LectureTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String

    init(title: String = "Lectures") {
        self.title = title
    }
}
