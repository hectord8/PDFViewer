import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorView: View {
    #if HOT_RELOAD
        @ObserveInjection private var inject
    #endif

    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var workbooks: WorkbookStore
    @ObservedObject var note: NoteTab
    @State private var showSaveToWorkbook = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RichTextEditorView(text: $note.text, onChanged: { note.markChanged() })
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showSaveToWorkbook) {
            SaveToWorkbookSheet(title: note.title) { workbookID, folderID in
                note.saveNow()
                guard let url = note.fileURL else { return }
                workbooks.add(
                    workbooks.makeItem(kind: .note, title: note.title, url: url),
                    to: workbookID,
                    folderID: folderID
                )
            }
        }
        .hotReload()
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Note title", text: $note.title)
                .textFieldStyle(.plain)
                .font(.title3.bold())
                .onSubmit { note.saveNow() }

            if note.isDirty {
                Text("Saving…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Saved", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.selectedTab != nil {
                Button {
                    store.splitNoteWithPDF(note)
                } label: {
                    Label("Split with PDF", systemImage: "rectangle.split.2x1")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show this note beside the current PDF")
            }

            Button("Save") {
                note.saveNow()
            }
            .controlSize(.small)

            Menu {
                Button("Word Document (.docx)…") {
                    export(extension: "docx", type: UTType(filenameExtension: "docx") ?? .data) { url in
                        NotesStore.writeDocx(note.text, to: url)
                    }
                }
                Button("PDF…") {
                    export(extension: "pdf", type: .pdf) { url in
                        NotesStore.writePDF(note.text, to: url)
                    }
                }
                Button("Plain Text (.txt)…") {
                    export(extension: "txt", type: .plainText) { url in
                        do {
                            try note.text.string.write(to: url, atomically: true, encoding: .utf8)
                            return true
                        } catch {
                            NSLog("PDFViewer: could not save text: \(error.localizedDescription)")
                            return false
                        }
                    }
                }
                Button("Rich Text (.rtf)…") {
                    export(extension: "rtf", type: .rtf) { url in
                        NotesStore.save(note.text, title: note.title, to: url) != nil
                    }
                }
                Divider()
                Button("Save to Workbook…") {
                    note.saveNow()
                    showSaveToWorkbook = true
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export this note")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func export(extension ext: String, type: UTType, writer: (URL) -> Bool) {
        note.saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(note.title).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = writer(url)
    }
}

/// An NSTextView that handles the standard rich-text shortcuts (⌘B, ⌘I, ⌘U)
/// and uses Tab/Shift-Tab to indent rather than inserting a tab character.
final class NoteTextView: NSTextView {
    var onToggleBold: (() -> Void)?
    var onToggleItalic: (() -> Void)?
    var onToggleUnderline: (() -> Void)?
    var onIndent: (() -> Void)?
    var onOutdent: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {  // Tab
            if event.modifierFlags.contains(.shift) {
                onOutdent?()
            } else {
                onIndent?()
            }
            return
        }
        if event.keyCode == 51, backspaceDedents() {  // Backspace at line start
            onOutdent?()
            return
        }
        super.keyDown(with: event)
    }

    /// True when Backspace is pressed with the caret at the very start of an
    /// indented paragraph, so it should outdent rather than delete.
    private func backspaceDedents() -> Bool {
        let selection = selectedRange()
        guard selection.length == 0 else { return false }

        let ns = string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: selection.location, length: 0))

        // Position of the first non-tab character in the paragraph.
        var contentStart = paragraph.location
        while contentStart < paragraph.location + paragraph.length,
            ns.substring(with: NSRange(location: contentStart, length: 1)) == "\t"
        {
            contentStart += 1
        }
        guard selection.location == contentStart else { return false }

        if let style = textStorage?.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
            as? NSParagraphStyle,
            style.headIndent > 0
        {
            return true
        }
        return contentStart > paragraph.location
    }

    // MARK: - Images (screenshots) dropped or pasted in

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        image(from: sender) != nil ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        image(from: sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = image(from: sender) else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        insertImage(image, at: characterIndexForInsertion(at: point))
        return true
    }

    override func paste(_ sender: Any?) {
        if let image = image(from: NSPasteboard.general) {
            insertImage(image, at: selectedRange().location)
            return
        }
        super.paste(sender)
    }

    private func image(from sender: NSDraggingInfo) -> NSImage? {
        image(from: sender.draggingPasteboard)
    }

    private func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
            let first = images.first
        {
            return first
        }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], let image = urls.first.flatMap({ NSImage(contentsOf: $0) }) {
            return image
        }
        return nil
    }

    private func insertImage(_ image: NSImage, at index: Int) {
        let maxWidth: CGFloat = 420
        var size = image.size
        if size.width > maxWidth, size.width > 0 {
            size = NSSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(origin: .zero, size: size)

        guard let storage = textStorage else { return }
        let location = min(max(index, 0), storage.length)
        storage.replaceCharacters(
            in: NSRange(location: location, length: 0), with: NSAttributedString(attachment: attachment))
        didChangeText()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
            !event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.control)
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b":
            onToggleBold?()
            return true
        case "i":
            onToggleItalic?()
            return true
        case "u":
            onToggleUnderline?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// A word-processor style editor: a formatting bar over a rich NSTextView.
struct RichTextEditorView: NSViewRepresentable {
    @Binding var text: NSAttributedString
    var onChanged: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let textView = NoteTextView()
        textView.onToggleBold = { [weak coordinator = context.coordinator] in coordinator?.applyBold() }
        textView.onToggleItalic = { [weak coordinator = context.coordinator] in coordinator?.applyItalic() }
        textView.onToggleUnderline = { [weak coordinator = context.coordinator] in coordinator?.applyUnderline() }
        textView.onIndent = { [weak coordinator = context.coordinator] in coordinator?.indent(by: 22) }
        textView.onOutdent = { [weak coordinator = context.coordinator] in coordinator?.indent(by: -22) }
        textView.registerForDraggedTypes([.tiff, .png, .fileURL])
        textView.isRichText = true
        textView.allowsUndo = true
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textStorage?.setAttributedString(text)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.textView = textView

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = context.coordinator.makeToolbar()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbar)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),

            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if !textView.attributedString().isEqual(to: text) {
            textView.textStorage?.setAttributedString(text)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditorView
        weak var textView: NSTextView?

        init(_ parent: RichTextEditorView) {
            self.parent = parent
        }

        func makeToolbar() -> NSView {
            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)

            let bold = NSButton(title: "B", target: self, action: #selector(toggleBold))
            bold.font = NSFont.boldSystemFont(ofSize: 12)

            let italic = NSButton(title: "I", target: self, action: #selector(toggleItalic))
            italic.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)

            let underline = NSButton(title: "U", target: self, action: #selector(toggleUnderline))
            underline.font = NSFont.systemFont(ofSize: 12)

            for button in [bold, italic, underline] {
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.setButtonType(.momentaryPushIn)
                stack.addArrangedSubview(button)
            }

            let size = NSPopUpButton()
            size.addItems(withTitles: ["12", "13", "14", "15", "16", "18", "20", "24", "28"])
            size.selectItem(withTitle: "13")
            size.target = self
            size.action = #selector(changeSize(_:))
            size.bezelStyle = .rounded
            size.controlSize = .small
            stack.addArrangedSubview(size)

            let bullet = NSButton(title: "•", target: self, action: #selector(toggleBulletList))
            bullet.toolTip = "Bullet list"
            let numbered = NSButton(title: "1.", target: self, action: #selector(toggleNumberedList))
            numbered.toolTip = "Numbered list"
            let table = NSButton(title: "▦", target: self, action: #selector(insertTable))
            table.toolTip = "Insert a table"

            for button in [bullet, numbered, table] {
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.setButtonType(.momentaryPushIn)
                stack.addArrangedSubview(button)
            }

            return stack
        }

        // MARK: - Lists

        @objc private func toggleBulletList() {
            toggleList(marker: .disc)
        }

        @objc private func toggleNumberedList() {
            toggleList(marker: .decimal)
        }

        private func toggleList(marker: NSTextList.MarkerFormat) {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())

            storage.beginEditing()
            storage.enumerateAttribute(.paragraphStyle, in: paragraphRange, options: []) { value, subRange, _ in
                let style =
                    (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                if !style.textLists.isEmpty {
                    style.textLists = []
                    style.headIndent = 0
                    style.firstLineHeadIndent = 0
                    style.tabStops = []
                } else {
                    style.textLists = [NSTextList(markerFormat: marker, options: 0)]
                    style.headIndent = 22
                    style.firstLineHeadIndent = 0
                    style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]
                }
                storage.addAttribute(.paragraphStyle, value: style, range: subRange)
            }
            storage.endEditing()
            notifyChange()
        }

        // MARK: - Tables

        @objc private func insertTable() {
            guard let textView, let storage = textView.textStorage else { return }

            let rows = 3
            let columns = 3
            let table = NSTextTable()
            table.numberOfColumns = columns
            table.layoutAlgorithm = .automaticLayoutAlgorithm
            table.collapsesBorders = true
            table.hidesEmptyCells = false

            let font = textView.font ?? NSFont.systemFont(ofSize: 13)
            let built = NSMutableAttributedString()

            for row in 0..<rows {
                for column in 0..<columns {
                    let block = NSTextTableBlock(
                        table: table,
                        startingRow: row,
                        rowSpan: 1,
                        startingColumn: column,
                        columnSpan: 1
                    )
                    block.setBorderColor(.gridColor)
                    block.setWidth(1, type: .absoluteValueType, for: .border)
                    block.setWidth(4, type: .absoluteValueType, for: .padding)

                    let style = NSMutableParagraphStyle()
                    style.textBlocks = [block]

                    built.append(
                        NSAttributedString(
                            string: "\u{200B}\n",
                            attributes: [.paragraphStyle: style, .font: font]
                        )
                    )
                }
            }

            storage.insert(built, at: textView.selectedRange().location)
            notifyChange()
        }

        private func applyFont(_ transform: (NSFont) -> NSFont) {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()

            if range.length == 0 {
                var attributes = textView.typingAttributes
                let font = (attributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                attributes[.font] = transform(font)
                textView.typingAttributes = attributes
                return
            }

            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 13)
                storage.addAttribute(.font, value: transform(font), range: subRange)
            }
            storage.endEditing()
            notifyChange()
        }

        @objc private func toggleBold() { applyBold() }
        @objc private func toggleItalic() { applyItalic() }
        @objc private func toggleUnderline() { applyUnderline() }

        func applyBold() {
            applyFont { font in
                let traits = NSFontManager.shared.traits(of: font)
                return traits.contains(.boldFontMask)
                    ? NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
                    : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        }

        func applyItalic() {
            applyFont { font in
                let traits = NSFontManager.shared.traits(of: font)
                return traits.contains(.italicFontMask)
                    ? NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
                    : NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
        }

        func applyUnderline() {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            storage.addAttribute(
                .underlineStyle, value: current == 0 ? NSUnderlineStyle.single.rawValue : 0, range: range)
            notifyChange()
        }

        /// Indents (or outdents) the selected paragraphs instead of inserting a
        /// tab character, which keeps the layout stable. Outdenting also removes
        /// a leading tab, so notes that used real tabs can be brought back left.
        func indent(by delta: CGFloat) {
            guard let textView, let storage = textView.textStorage else { return }

            if delta < 0, removeLeadingTab(storage: storage) {
                notifyChange()
                return
            }

            let paragraphRange = (storage.string as NSString).paragraphRange(for: textView.selectedRange())

            storage.beginEditing()
            storage.enumerateAttribute(.paragraphStyle, in: paragraphRange, options: []) { value, subRange, _ in
                let style =
                    (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                style.firstLineHeadIndent = max(0, style.firstLineHeadIndent + delta)
                style.headIndent = max(0, style.headIndent + delta)
                if !style.textLists.isEmpty {
                    style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
                }
                storage.addAttribute(.paragraphStyle, value: style, range: subRange)
            }
            storage.endEditing()

            if storage.length > 0 {
                let location = min(textView.selectedRange().location, storage.length - 1)
                if let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
                    as? NSParagraphStyle
                {
                    var attributes = textView.typingAttributes
                    attributes[.paragraphStyle] = style
                    textView.typingAttributes = attributes
                }
            }
            notifyChange()
        }

        @objc private func changeSize(_ sender: NSPopUpButton) {
            guard let title = sender.selectedItem?.title, let value = Double(title) else { return }
            applyFont { NSFontManager.shared.convert($0, toSize: CGFloat(value)) }
        }

        func textDidChange(_ notification: Notification) {
            convertMarkdownListIfNeeded()
            notifyChange()
        }

        /// Removes one leading tab character from the paragraph at the caret.
        private func removeLeadingTab(storage: NSTextStorage) -> Bool {
            guard let textView else { return false }
            let ns = storage.string as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: textView.selectedRange().location, length: 0))
            guard paragraph.length > 0,
                ns.substring(with: NSRange(location: paragraph.location, length: 1)) == "\t"
            else {
                return false
            }
            storage.replaceCharacters(in: NSRange(location: paragraph.location, length: 1), with: "")
            return true
        }

        /// Turns "- ", "* ", "+ " into a bullet list and "1. " into a numbered
        /// list as you type, the way a Markdown editor does.
        private func convertMarkdownListIfNeeded() {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return }

            let ns = storage.string as NSString
            let paragraphRange = ns.paragraphRange(for: NSRange(location: selection.location, length: 0))
            var paragraph = ns.substring(with: paragraphRange)
            let endsWithNewline = paragraph.hasSuffix("\n")
            if endsWithNewline { paragraph = String(paragraph.dropLast()) }

            let caretAtEnd =
                selection.location == paragraphRange.location + paragraphRange.length
                || (endsWithNewline && selection.location == paragraphRange.location + paragraphRange.length - 1)
            guard caretAtEnd else { return }

            let marker: NSTextList.MarkerFormat?
            switch paragraph {
            case "- ", "* ", "+ ": marker = .disc
            case "1. ": marker = .decimal
            default: marker = nil
            }
            guard let marker else { return }

            var textRange = paragraphRange
            if endsWithNewline { textRange.length -= 1 }

            storage.beginEditing()
            storage.replaceCharacters(in: textRange, with: "")
            let style = NSMutableParagraphStyle()
            style.textLists = [NSTextList(markerFormat: marker, options: 0)]
            style.headIndent = 22
            style.firstLineHeadIndent = 0
            style.tabStops = [NSTextTab(textAlignment: .left, location: 22)]

            let font = textView.font ?? NSFont.systemFont(ofSize: 13)
            let newRange = (storage.string as NSString).paragraphRange(
                for: NSRange(location: textRange.location, length: 0))
            if newRange.length > 0 {
                storage.addAttribute(.paragraphStyle, value: style, range: newRange)
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.textColor]
        }

        private func notifyChange() {
            guard let textView else { return }
            parent.text = textView.attributedString()
            parent.onChanged()
        }
    }
}
