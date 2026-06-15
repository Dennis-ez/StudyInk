import UIKit
import PencilKit

/// Assembles the full multimodal context the AI tutor sees on every request:
/// all pages as images, OCR text, typed text, note metadata, and the
/// focused region when the student circled something.
enum NoteContextBuilder {
    struct Context {
        var blocks: [AIContent]
    }

    @MainActor
    static func build(
        note: Note,
        currentPageIndex: Int,
        darkMode: Bool,
        focusRegion: CGRect? = nil,
        focusImage: UIImage? = nil
    ) async -> Context {
        var blocks: [AIContent] = []
        let pages = note.sortedPages

        var summary = """
        Note title: \(note.title ?? "Untitled")
        Subject folder: \(note.subject?.name ?? "None")
        Total pages: \(pages.count). The student is currently on page \(currentPageIndex + 1).
        """

        // Snapshot pages on the main actor (cheap), render off it (expensive) —
        // asking the AI must never freeze the canvas or keyboard.
        let snapshots = pages.map(PageRenderer.Snapshot.init)
        let images = await Task.detached(priority: .userInitiated) {
            snapshots.enumerated().map { index, snapshot in
                // Page images scaled down to keep payloads light; current page sharper.
                PageRenderer.render(snapshot, darkMode: darkMode, scale: index == currentPageIndex ? 1.0 : 0.5)
            }
        }.value

        for (index, page) in pages.enumerated() {
            if images.indices.contains(index), let block = AIContent.image(images[index]) {
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
            summary += "\nIMPORTANT: The student circled a specific region on page \(currentPageIndex + 1) (at x:\(Int(focusRegion.minX)) y:\(Int(focusRegion.minY)) w:\(Int(focusRegion.width)) h:\(Int(focusRegion.height))). The cropped image below shows EXACTLY what they circled — answer ONLY about that content. The other page images are background context; do not answer about them unless the circled content explicitly refers to them."
        }
        if let focusImage, let block = AIContent.image(focusImage) {
            blocks.append(.text("Cropped image of the circled region (this is what the student is asking about):"))
            blocks.append(block)
        }

        blocks.append(.text(summary))
        return Context(blocks: blocks)
    }

    /// Fresh OCR lines for the current page, used to resolve annotation targets.
    @MainActor
    static func ocrLines(for page: Page) async -> [OCRLine] {
        let snapshot = PageRenderer.Snapshot(page: page)
        return await Task.detached(priority: .userInitiated) {
            let image = PageRenderer.render(snapshot, darkMode: false)
            return await OCRService.recognize(image: image, pageSize: snapshot.pageSize)
        }.value
    }
}
