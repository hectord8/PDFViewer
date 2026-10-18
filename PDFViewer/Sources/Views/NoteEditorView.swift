import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NoteEditorView: View {
    @EnvironmentObject private var store: LibraryStore
    @ObservedObject var note: NoteTab

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            RichTextEditorView(text: $note.text, onChanged: { note.markChanged() })
        }
        .background(Color(nsColor: .textBackgroundColor))
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
                Button("Rich Text (.rtf)…") {
                    export(extension: "rtf", type: .rtf) { url in
                        NotesStore.save(note.text, title: note.title, to: url) != nil
                    }
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

/// A word-processor style editor: a formatting bar over a rich NSTextView.
struct RichTextEditorView: NSViewRepresentable {
    @Binding var text: NSAttributedString
    var onChanged: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let textView = NSTextView()
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
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
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
                let style = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
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

        @objc private func toggleBold() {
            applyFont { font in
                let traits = NSFontManager.shared.traits(of: font)
                return traits.contains(.boldFontMask)
                    ? NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
                    : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
        }

        @objc private func toggleItalic() {
            applyFont { font in
                let traits = NSFontManager.shared.traits(of: font)
                return traits.contains(.italicFontMask)
                    ? NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
                    : NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
        }

        @objc private func toggleUnderline() {
            guard let textView, let storage = textView.textStorage else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { return }
            let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            storage.addAttribute(.underlineStyle, value: current == 0 ? NSUnderlineStyle.single.rawValue : 0, range: range)
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

            let caretAtEnd = selection.location == paragraphRange.location + paragraphRange.length
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
            let newRange = (storage.string as NSString).paragraphRange(for: NSRange(location: textRange.location, length: 0))
            if newRange.length > 0 {
                storage.addAttribute(.paragraphStyle, value: style, range: newRange)
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .paragraphStyle: style]
        }

        private func notifyChange() {
            guard let textView else { return }
            parent.text = textView.attributedString()
            parent.onChanged()
        }
    }
}
