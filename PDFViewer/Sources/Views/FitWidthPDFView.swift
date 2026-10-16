import PDFKit

/// A `PDFView` that tells us when its width changes, which is what drives
/// fit-to-width.
final class FitWidthPDFView: PDFView {
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onWidthChange?()
    }
}