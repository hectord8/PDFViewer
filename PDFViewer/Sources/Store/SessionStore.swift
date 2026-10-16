import Foundation

/// Reads and writes `session.json` in ~/Library/Application Support/<bundle id>/.
enum SessionStore {

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        let folderName = Bundle.main.bundleIdentifier ?? "PDFViewer"
        let folder = base.appendingPathComponent(folderName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("session.json", isDirectory: false)
    }

    static func load() -> Session? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func save(_ session: Session) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(session).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("PDFViewer: could not save session: \(error.localizedDescription)")
        }
    }

    /// A bookmark survives the file being moved or renamed. The plain path is
    /// kept as a fallback in case the bookmark cannot be resolved.
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ state: TabState) -> URL? {
        resolve(path: state.path, bookmark: state.bookmark)
    }

    static func resolve(path: String, bookmark: Data?) -> URL? {
        if let bookmark = bookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), FileManager.default.isReadableFile(atPath: url.path) {
                return url
            }
        }

        let url = URL(fileURLWithPath: path)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }
}