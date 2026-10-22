import AppKit
import Foundation

/// Reads and writes rich-text notes as `.rtf` in ~/Documents/PDFViewer/Notes.
enum NotesStore {
    static var folderURL: URL {
        let documents =
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        let folder =
            documents
            .appendingPathComponent("PDFViewer", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func emptyText() -> NSAttributedString {
        NSAttributedString(
            string: "",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.textColor,
            ]
        )
    }

    static func load(_ url: URL) -> (title: String, text: NSAttributedString)? {
        guard let text = try? NSMutableAttributedString(url: url, options: [:], documentAttributes: nil) else {
            return nil
        }
        return (url.deletingPathExtension().lastPathComponent, text)
    }

    static func save(_ text: NSAttributedString, title: String, to existing: URL?) -> URL? {
        let folder = folderURL
        let url = existing ?? uniqueURL(in: folder, slug: slug(title))
        let range = NSRange(location: 0, length: text.length)

        // Legacy plain .rtf notes keep their format.
        if url.pathExtension.lowercased() == "rtf" {
            guard
                let data = try? text.data(
                    from: range,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                )
            else {
                return nil
            }
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                NSLog("PDFViewer: could not save note: \(error.localizedDescription)")
                return nil
            }
        }

        // .rtfd bundles can embed images (screenshots).
        guard
            let wrapper = try? text.fileWrapper(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            )
        else {
            return nil
        }
        do {
            try? FileManager.default.removeItem(at: url)
            try wrapper.write(to: url, options: .atomic, originalContentsURL: nil)
            return url
        } catch {
            NSLog("PDFViewer: could not save note: \(error.localizedDescription)")
            return nil
        }
    }

    static func writeDocx(_ text: NSAttributedString, to url: URL) -> Bool {
        let range = NSRange(location: 0, length: text.length)
        guard
            let data = try? text.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
            )
        else {
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("PDFViewer: could not export .docx: \(error.localizedDescription)")
            return false
        }
    }

    static func writePDF(_ text: NSAttributedString, to url: URL) -> Bool {
        let printInfo = NSPrintInfo()
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        printInfo.topMargin = 40
        printInfo.bottomMargin = 40
        printInfo.leftMargin = 48
        printInfo.rightMargin = 48
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic

        let pageWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: max(pageWidth, 200), height: 100))
        textView.textStorage?.setAttributedString(text)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }

    static func list() -> [URL] {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        return
            entries
            .filter { ["rtf", "rtfd"].contains($0.pathExtension.lowercased()) }
            .sorted { first, second in
                let a =
                    (try? first.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                let b =
                    (try? second.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                return a > b
            }
    }

    private static func uniqueURL(in folder: URL, slug: String) -> URL {
        var candidate = folder.appendingPathComponent("\(slug).rtfd")
        var suffix = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(slug) \(suffix).rtfd")
            suffix += 1
        }
        return candidate
    }

    private static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let replaced = text.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(replaced).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "note" : String(collapsed.prefix(60))
    }
}
