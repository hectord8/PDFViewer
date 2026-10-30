import AppKit
import PDFKit

/// A `PDFView` that tells us when its width changes, which is what drives
/// fit-to-width, and lets its tab add items to the right-click menu.
final class FitWidthPDFView: PDFView {
    var onWidthChange: (() -> Void)?
    var onFocus: (() -> Void)?

    /// Extra items shown at the top of the right-click menu. Receives the
    /// click location in this view's coordinates.
    var contextMenuItems: ((NSPoint) -> [NSMenuItem])?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onWidthChange?()
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        let extra = contextMenuItems?(point) ?? []
        guard !extra.isEmpty else { return menu }

        for (offset, item) in extra.enumerated() {
            menu.insertItem(item, at: offset)
        }
        if menu.items.count > extra.count {
            menu.insertItem(.separator(), at: extra.count)
        }
        return menu
    }
}

/// An `NSMenuItem` that runs a closure, so menus can be built without
/// target/selector plumbing.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: String? = nil, tint: NSColor? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let image {
            var symbol = NSImage(systemSymbolName: image, accessibilityDescription: nil)
            if let tint {
                symbol = symbol?.withSymbolConfiguration(.init(paletteColors: [tint]))
            }
            self.image = symbol
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func fire() {
        handler()
    }
}
