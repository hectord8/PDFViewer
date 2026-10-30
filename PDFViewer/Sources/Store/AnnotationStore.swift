import AppKit
import Foundation

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow
    case green
    case blue
    case pink

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .pink: return .systemPink
        }
    }
}

enum HighlightStyle: String, Codable {
    case highlight
    case underline
}

/// A highlight the reader made on one page. Rects are in page space, so they
/// line up again whatever the zoom.
struct StoredHighlight: Codable, Identifiable, Equatable {
    var id: UUID
    var page: Int
    var rects: [[Double]]
    var color: HighlightColor
    var style: HighlightStyle
    var text: String

    var cgRects: [CGRect] {
        rects.compactMap { values in
            guard values.count == 4 else { return nil }
            return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }
}

/// Persists per-page notes and highlights beside the other saved material,
/// keyed by the PDF path so reopening a document brings its annotations back.
/// The PDF file itself is never modified.
enum AnnotationStore {
    private struct File: Codable {
        var path: String
        var title: String
        var notes: [String: String]
        var highlights: [StoredHighlight]?
    }

    private static let queue = DispatchQueue(label: "com.example.PDFViewer.annotations")
    /// One pending write per file, so saving one PDF never cancels another's.
    private static var pendingSaves: [URL: DispatchWorkItem] = [:]

    static var folderURL: URL {
        let documents =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let folder =
            documents
            .appendingPathComponent("PDFViewer", isDirectory: true)
            .appendingPathComponent("Annotations", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func loadFile(pdfPath: String, title: String) -> File? {
        guard let data = try? Data(contentsOf: fileURL(pdfPath: pdfPath, title: title)) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }

    static func load(pdfPath: String, title: String) -> [Int: String] {
        guard let file = loadFile(pdfPath: pdfPath, title: title) else { return [:] }
        var result: [Int: String] = [:]
        for (key, value) in file.notes {
            if let index = Int(key) {
                result[index] = value
            }
        }
        return result
    }

    static func loadHighlights(pdfPath: String, title: String) -> [StoredHighlight] {
        loadFile(pdfPath: pdfPath, title: title)?.highlights ?? []
    }

    static func save(
        _ notes: [Int: String],
        highlights: [StoredHighlight] = [],
        pdfPath: String,
        title: String
    ) {
        var encoded: [String: String] = [:]
        for (index, note) in notes {
            encoded[String(index)] = note
        }
        let file = File(
            path: pdfPath,
            title: title,
            notes: encoded,
            highlights: highlights.isEmpty ? nil : highlights
        )
        let url = fileURL(pdfPath: pdfPath, title: title)

        pendingSaves[url]?.cancel()
        let work = DispatchWorkItem {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(file).write(to: url, options: .atomic)
            } catch {
                NSLog("PDFViewer: could not save annotations: \(error.localizedDescription)")
            }
        }
        pendingSaves[url] = work
        queue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    static func delete(pdfPath: String, title: String) {
        try? FileManager.default.removeItem(at: fileURL(pdfPath: pdfPath, title: title))
    }

    private static func fileURL(pdfPath: String, title: String) -> URL {
        folderURL.appendingPathComponent("\(slug(title))-\(shortHash(pdfPath)).json", isDirectory: false)
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let replaced = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(replaced).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "notes" : String(collapsed.prefix(60))
    }

    private static func shortHash(_ string: String) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash))
    }
}
