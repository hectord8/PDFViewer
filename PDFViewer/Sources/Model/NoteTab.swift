import AppKit

/// A rich-text note that opens as its own tab (or beside a PDF). Saved to disk
/// as RTF so formatting is preserved.
final class NoteTab: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var text: NSAttributedString
    @Published var fileURL: URL?
    @Published var isDirty = false

    /// Called the first time the note is written to disk.
    var onFirstSave: ((NoteTab) -> Void)?

    private var saveWork: DispatchWorkItem?

    init(title: String, text: NSAttributedString, fileURL: URL?) {
        self.title = title
        self.text = text
        self.fileURL = fileURL
    }

    /// Called on every edit — autosaves shortly after typing stops.
    func markChanged() {
        isDirty = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let wasUnsaved = fileURL == nil
        guard let url = NotesStore.save(text, title: title, to: fileURL) else { return }
        fileURL = url
        isDirty = false
        if wasUnsaved {
            onFirstSave?(self)
        }
    }
}
