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
        focusImage: UIImage? = nil,
        focusAnchor: CGPoint? = nil
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
                // The current page is rendered at 2× so the model can READ small
                // handwritten notation (stacked fractions, limit subscripts,
                // exponents) — at 1× it can't and silently skips them. Other
                // pages stay light (0.5×) since they're only background context.
                PageRenderer.render(snapshot, darkMode: darkMode, scale: index == currentPageIndex ? 2.0 : 0.5)
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

        // ORIENTATION: a deterministic map of WHAT the student is solving and
        // WHERE they're focused, so the model doesn't have to be spoon-fed. Put
        // it FIRST so the model orients before reading the page images.
        if pages.indices.contains(currentPageIndex) {
            let anchor = focusAnchor ?? focusRegion.map { CGPoint(x: $0.midX, y: $0.midY) }
            let lines = await ocrLines(for: pages[currentPageIndex])
            let orient = orientation(page: pages[currentPageIndex], pageIndex: currentPageIndex,
                                     lines: lines, focusAnchor: anchor)
            if !orient.isEmpty { blocks.insert(.text(orient), at: 0) }
        }

        return Context(blocks: blocks)
    }

    /// Builds the orientation summary from the current page's OCR + the student's
    /// focus point: the problem statement, the labelled sub-questions, and which
    /// one the student is currently working on.
    @MainActor
    private static func orientation(page: Page, pageIndex: Int, lines: [OCRLine], focusAnchor: CGPoint?) -> String {
        let mediaFrames = page.mediaItems.map(\.frame)
        let inMedia: (OCRLine) -> Bool = { line in mediaFrames.contains { $0.intersects(line.rect) } }
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        // The pasted/printed question (inside a media frame) + any typed text.
        let problem = clean(lines.filter(inMedia).map(\.text).joined(separator: " "))
        let typed = clean(page.textBoxes.map(\.text).filter { !$0.isEmpty }.joined(separator: " "))
        let work = lines.filter { !inMedia($0) }
        // Sub-question labels — headers usually end with a colon (often Hebrew RTL).
        let headers = work.filter { clean($0.text).hasSuffix(":") || clean($0.text).hasSuffix("：") }

        var s = "STUDENT CONTEXT — orient yourself with this before answering (figure out WHICH problem/sub-question and WHERE the student is, so you don't need to be told):\n"
        let problemText = [problem, typed].filter { !$0.isEmpty }.joined(separator: " | ")
        if !problemText.isEmpty {
            s += "• THE PROBLEM/TASK (from the printed/pasted question): \"\(problemText.prefix(700))\"\n"
        } else {
            s += "• No explicit problem statement was OCR'd on this page — read it from the page image (it may be a pasted screenshot or on an earlier page).\n"
        }
        if !headers.isEmpty {
            s += "• Sub-questions the student has labelled (top→bottom): \(headers.map { clean($0.text) }.joined(separator: " · "))\n"
        }
        if let anchor = focusAnchor, !work.isEmpty {
            let nearest = work.min { hypot($0.rect.midX - anchor.x, $0.rect.midY - anchor.y)
                                   < hypot($1.rect.midX - anchor.x, $1.rect.midY - anchor.y) }
            // The labelled sub-question the focus sits under (nearest header above).
            let headerAbove = headers.filter { $0.rect.midY <= anchor.y + 8 }
                .max { $0.rect.midY < $1.rect.midY }
            s += "• THE STUDENT IS FOCUSED at (x:\(Int(anchor.x)), y:\(Int(anchor.y))) on page \(pageIndex + 1)."
            if let nearest { s += " Their nearest handwriting reads: \"\(clean(nearest.text))\"." }
            if let headerAbove { s += " That is under the sub-question: \"\(clean(headerAbove.text))\"." }
            s += " Answer about THIS part of their work unless the question clearly points elsewhere.\n"
        }
        return s
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
