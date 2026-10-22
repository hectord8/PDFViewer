import Foundation

/// Persists per-page notes beside the other saved material, keyed by the PDF
/// path so reopening a document brings its annotations back.
enum AnnotationStore {
    private struct File: Codable {
        var path: String
        var title: String
        var notes: [String: String]
    }

    private static let queue = DispatchQueue(label: "com.example.PDFViewer.annotations")
    private static var pendingSave: DispatchWorkItem?

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

    static func load(pdfPath: String, title: String) -> [Int: String] {
        guard let data = try? Data(contentsOf: fileURL(pdfPath: pdfPath, title: title)),
            let file = try? JSONDecoder().decode(File.self, from: data)
        else {
            return [:]
        }
        var result: [Int: String] = [:]
        for (key, value) in file.notes {
            if let index = Int(key) {
                result[index] = value
            }
        }
        return result
    }

    static func save(_ notes: [Int: String], pdfPath: String, title: String) {
        var encoded: [String: String] = [:]
        for (index, note) in notes {
            encoded[String(index)] = note
        }
        let file = File(path: pdfPath, title: title, notes: encoded)
        let url = fileURL(pdfPath: pdfPath, title: title)

        pendingSave?.cancel()
        let work = DispatchWorkItem {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(file).write(to: url, options: .atomic)
            } catch {
                NSLog("PDFViewer: could not save annotations: \(error.localizedDescription)")
            }
        }
        pendingSave = work
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
