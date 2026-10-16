import PDFKit

/// A `PDFView` that tells us when its width changes, which is what drives
/// fit-to-width.
final class FitWidthPDFView: PDFView {
    var onWidthChange: (() -> Void)?
    var onFocus: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onWidthChange?()
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
}