import Foundation

/// A saved Echo360 lesson. The portal keeps these in a local list so they can
/// be reopened without re-navigating the Echo360 course pages.
struct Lecture: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var course: String = ""
    var lessonURL: String
    var mediaID: String?
    var transcriptURL: String?
    var lastOpened: Date?

    init(
        id: UUID = UUID(),
        title: String,
        course: String = "",
        lessonURL: String,
        mediaID: String? = nil,
        transcriptURL: String? = nil,
        lastOpened: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.course = course
        self.lessonURL = lessonURL
        self.mediaID = mediaID
        self.transcriptURL = transcriptURL
        self.lastOpened = lastOpened
    }

    var url: URL? { URL(string: lessonURL) }
    var displayTitle: String { title.isEmpty ? "Echo360 lecture" : title }
}
