import UIKit
import PencilKit

/// Assembles the full multimodal context Claude sees on every request:
/// all pages as images, OCR text, typed text, note metadata, and the
/// focused region when the student circled something.
enum NoteContextBuilder {
    struct Context {
        var blocks: [ClaudeService.ContentBlock]
    }

    @MainActor
    static func build(
        note: Note,
        currentPageIndex: Int,
        darkMode: Bool,
        focusRegion: CGRect? = nil,
        focusImage: UIImage? = nil
    ) async -> Context {
        var blocks: [ClaudeService.ContentBlock] = []
        let pages = note.sortedPages

        var summary = """
        Note title: \(note.title ?? "Untitled")
        Subject folder: \(note.subject?.name ?? "None")
        Total pages: \(pages.count). The student is currently on page \(currentPageIndex + 1).
        """

        for (index, page) in pages.enumerated() {
            // Page snapshots scaled down to keep payloads light; current page sharper.
            let scale: CGFloat = index == currentPageIndex ? 1.0 : 0.5
            let image = PageRenderer.image(for: page, darkMode: darkMode, scale: scale)
            if let block = ClaudeService.ContentBlock.image(image) {
                blocks.append(.text("Page \(index + 1) image:"))
                blocks.append(block)
            }

            let typed = page.textBoxes.map(\.text).filter { !$0.isEmpty }
            if !typed.isEmpty {
                summary += "\nPage \(index + 1) typed text:\n" + typed.joined(separator: "\n")
            }
            if let ocr = page.ocrText, !ocr.isEmpty {
                summary += "\nPage \(index + 1) handwriting OCR:\n" + ocr
            }
        }

        if let focusRegion {
            summary += "\nThe student circled/selected the region at x:\(Int(focusRegion.minX)) y:\(Int(focusRegion.minY)) w:\(Int(focusRegion.width)) h:\(Int(focusRegion.height)) on the current page. Focus your answer there."
        }
        if let focusImage, let block = ClaudeService.ContentBlock.image(focusImage) {
            blocks.append(.text("Cropped image of the circled region:"))
            blocks.append(block)
        }

        blocks.append(.text(summary))
        return Context(blocks: blocks)
    }

    /// Fresh OCR lines for the current page, used to resolve annotation targets.
    @MainActor
    static func ocrLines(for page: Page) async -> [OCRLine] {
        let pageSize = PageSize.from(id: page.pageSizeID).size
        let image = PageRenderer.image(for: page, darkMode: false)
        return await OCRService.recognize(image: image, pageSize: pageSize)
    }
}
