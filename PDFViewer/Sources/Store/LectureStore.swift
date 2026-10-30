import Foundation

/// Saved Echo360 lessons, persisted to `lectures.json` in Application Support.
final class LectureStore: ObservableObject {
    static let shared = LectureStore()

    @Published private(set) var lectures: [Lecture] = []

    private let defaults: UserDefaults
    private let storageDirectory: URL
    private var saveWorkItem: DispatchWorkItem?

    private static let lastLectureKey = "lastLectureID"

    init(defaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.defaults = defaults
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else {
            let base =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.storageDirectory = base.appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "PDFViewer", isDirectory: true)
        }
        load()
    }

    var lastSelectedLectureID: UUID? {
        get { defaults.string(forKey: Self.lastLectureKey).flatMap(UUID.init(uuidString:)) }
        set { defaults.set(newValue?.uuidString, forKey: Self.lastLectureKey) }
    }

    // MARK: - Persistence

    private var fileURL: URL {
        if !FileManager.default.fileExists(atPath: storageDirectory.path) {
            try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        }
        return storageDirectory.appendingPathComponent("lectures.json", isDirectory: false)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([Lecture].self, from: data)
        else {
            return
        }
        lectures = decoded
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(lectures).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("PDFViewer: could not save lectures: \(error.localizedDescription)")
        }
    }

    // MARK: - Lectures

    @discardableResult
    func add(lessonURL: String, title: String = "", course: String = "") -> Lecture? {
        var value = lessonURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let url = URL(string: value), url.host != nil else { return nil }

        if let existing = lectures.first(where: { $0.lessonURL == value }) {
            return existing
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let lecture = Lecture(
            title: trimmedTitle.isEmpty ? Self.defaultTitle(for: url) : trimmedTitle,
            course: course.trimmingCharacters(in: .whitespacesAndNewlines),
            lessonURL: value
        )
        lectures.append(lecture)
        scheduleSave()
        return lecture
    }

    func remove(_ lecture: Lecture) {
        lectures.removeAll { $0.id == lecture.id }
        if lastSelectedLectureID == lecture.id {
            lastSelectedLectureID = nil
        }
        scheduleSave()
    }

    func rename(_ lecture: Lecture, to title: String) {
        guard let index = lectures.firstIndex(where: { $0.id == lecture.id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lectures[index].title = trimmed
        scheduleSave()
    }

    func markOpened(_ lecture: Lecture) {
        guard let index = lectures.firstIndex(where: { $0.id == lecture.id }) else { return }
        lectures[index].lastOpened = Date()
        lastSelectedLectureID = lecture.id
        scheduleSave()
    }

    func updateMediaID(_ lecture: Lecture, mediaID: String) {
        guard let index = lectures.firstIndex(where: { $0.id == lecture.id }),
            lectures[index].mediaID != mediaID
        else {
            return
        }
        lectures[index].mediaID = mediaID
        scheduleSave()
    }

    func updateTranscriptURL(_ lecture: Lecture, url: URL) {
        guard let index = lectures.firstIndex(where: { $0.id == lecture.id }) else { return }
        lectures[index].transcriptURL = url.absoluteString
        scheduleSave()
    }

    // MARK: - Transcript fetching

    func fetchTranscript(
        for lecture: Lecture,
        lessonID: String,
        mediaID: String,
        cookies: [HTTPCookie]
    ) async throws -> String {
        var endpoint: URL?
        if let raw = lecture.transcriptURL {
            endpoint = URL(string: raw)
        }
        if endpoint == nil, let lessonURL = lecture.url {
            endpoint = Self.transcriptEndpoint(lessonURL: lessonURL, lessonID: lessonID, mediaID: mediaID)
        }
        guard let endpoint else {
            throw LectureStoreError.invalidURL
        }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 30
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LectureStoreError.http(http.statusCode)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func transcriptEndpoint(lessonURL: URL, lessonID: String, mediaID: String) -> URL? {
        guard var components = URLComponents(url: lessonURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/api/ui/echoplayer/lessons/\(lessonID)/medias/\(mediaID)/transcript-file"
        components.queryItems = [URLQueryItem(name: "format", value: "vtt")]
        return components.url
    }

    static func lessonID(from url: URL?) -> String? {
        guard let url else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(where: { $0 == "lesson" || $0 == "lessons" }),
            parts.indices.contains(index + 1)
        else {
            return nil
        }
        return parts[index + 1]
    }

    private static func defaultTitle(for url: URL) -> String {
        if let lessonID = lessonID(from: url) {
            return "Lesson \(lessonID.prefix(8))"
        }
        return "Echo360 lecture"
    }
}

enum LectureStoreError: LocalizedError {
    case invalidURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Echo360 lesson URL is not valid."
        case .http(let status):
            return "Echo360 returned HTTP \(status). Sign in again in the player and retry."
        }
    }
}
