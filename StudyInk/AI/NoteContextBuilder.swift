import UIKit

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
        // Only send images for the pages the model actually needs: the CURRENT
        // page (2×, so small handwriting reads), plus the page(s) likely holding
        // the problem statement — page 1, and any page carrying a pasted question
        // image (media). Sending all 13 page images was a big token cost for no
        // gain. Every page's OCR text still goes into the summary below.
        let imageIndices: Set<Int> = {
            var s: Set<Int> = [currentPageIndex]
            if !snapshots.isEmpty { s.insert(0) }
            for (i, snap) in snapshots.enumerated() where !snap.mediaItems.isEmpty { s.insert(i) }
            return s
        }()
        let images: [Int: UIImage] = await Task.detached(priority: .userInitiated) {
            var result: [Int: UIImage] = [:]
            for index in imageIndices where snapshots.indices.contains(index) {
                // Clean, ALWAYS-LIGHT recognition render (dark ink on white, no ruled-line
                // noise) — far more legible to the vision model than the user's dark-mode
                // page (light ink on dark). Current page big so handwriting reads.
                result[index] = PageRenderer.recognitionImage(snapshots[index],
                                                              scale: index == currentPageIndex ? 2.0 : 0.6)
            }
            return result
        }.value

        for (index, page) in pages.enumerated() {
            if let image = images[index], let block = AIContent.image(image) {
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
            // The question (e.g. "1.A") is often on an EARLIER page (commonly the
            // first) while the answer is written here. Pull the printed/pasted
            // question text from earlier media-bearing pages so the model has it.
            var earlierProblem = ""
            for index in 0..<currentPageIndex where !pages[index].mediaItems.isEmpty {
                let p = problemText(from: await ocrLines(for: pages[index]), page: pages[index])
                if !p.isEmpty { earlierProblem += "\n[page \(index + 1)] " + p }
            }
            let orient = orientation(page: pages[currentPageIndex], pageIndex: currentPageIndex,
                                     lines: lines, focusAnchor: anchor, earlierProblem: earlierProblem)
            if !orient.isEmpty { blocks.insert(.text(orient), at: 0) }
        }

        return Context(blocks: blocks)
    }

    /// The printed/pasted question text on a page (OCR lines inside media frames).
    @MainActor
    private static func problemText(from lines: [OCRLine], page: Page) -> String {
        let frames = page.mediaItems.map(\.frame)
        let text = lines.filter { l in frames.contains { $0.intersects(l.rect) } }
            .map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the orientation summary from the current page's OCR + the student's
    /// focus point: the problem statement, the labelled sub-questions, and which
    /// one the student is currently working on.
    @MainActor
    private static func orientation(page: Page, pageIndex: Int, lines: [OCRLine],
                                    focusAnchor: CGPoint?, earlierProblem: String) -> String {
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
        let problemText = [problem, typed, clean(earlierProblem)].filter { !$0.isEmpty }.joined(separator: " | ")
        if !problemText.isEmpty {
            s += "• THE PROBLEM/TASK (from the printed/pasted question, which may be on an earlier page): \"\(problemText.prefix(900))\"\n"
        } else {
            s += "• No explicit problem statement was OCR'd — read it from the page images (it may be a pasted screenshot or on an earlier page).\n"
        }
        // The student often answers a numbered/lettered sub-question (1.A, סעיף א,
        // ב., q2…) written next to their answer — possibly far from the question.
        if let label = subQuestionLabel(in: work, near: focusAnchor) {
            s += "• The student appears to be answering sub-question \"\(label)\" — its FULL text is in the problem/page images (often the first page). Match their answer to THAT sub-question and grade/answer against it.\n"
        } else {
            s += "• The student may be answering a specific sub-question (e.g. 1.A / סעיף א) labelled near their work; the full question may be on an earlier page — find which part they're answering and use it.\n"
        }
        if !headers.isEmpty {
            s += "• Sub-questions the student has labelled here (top→bottom): \(headers.map { clean($0.text) }.joined(separator: " · "))\n"
        }
        if let anchor = focusAnchor, !work.isEmpty {
            let nearest = work.min { hypot($0.rect.midX - anchor.x, $0.rect.midY - anchor.y)
                                   < hypot($1.rect.midX - anchor.x, $1.rect.midY - anchor.y) }
            let headerAbove = headers.filter { $0.rect.midY <= anchor.y + 8 }
                .max { $0.rect.midY < $1.rect.midY }
            s += "• THE STUDENT IS FOCUSED at (x:\(Int(anchor.x)), y:\(Int(anchor.y))) on page \(pageIndex + 1)."
            if let nearest { s += " Their nearest handwriting reads: \"\(clean(nearest.text))\"." }
            if let headerAbove { s += " That is under the sub-question: \"\(clean(headerAbove.text))\"." }
            s += " Answer about THIS part of their work unless the question clearly points elsewhere.\n"
        }
        return s
    }

    private static let labelMatcher = try! NSRegularExpression(
        pattern: "\\b\\d+\\s*[.\\-)]?\\s*[A-Za-z]\\b|\\([A-Za-z]\\)|\\b\\d+\\.\\d+\\b|סעיף\\s*\\S+|שאלה\\s*\\S+",
        options: [])

    /// A sub-question label (1.A, (a), 1.1, "סעיף א", "שאלה 2") in the work, picking
    /// the one nearest the focus when several exist.
    private static func subQuestionLabel(in work: [OCRLine], near anchor: CGPoint?) -> String? {
        let candidates = work.sorted {
            guard let a = anchor else { return false }
            return hypot($0.rect.midX - a.x, $0.rect.midY - a.y) < hypot($1.rect.midX - a.x, $1.rect.midY - a.y)
        }
        for line in candidates {
            let t = line.text
            let range = NSRange(t.startIndex..., in: t)
            if let m = labelMatcher.firstMatch(in: t, range: range), let r = Range(m.range, in: t) {
                return String(t[r]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Fresh OCR lines for the current page, used to resolve annotation targets.
    @MainActor
    static func ocrLines(for page: Page) async -> [OCRLine] {
        let snapshot = PageRenderer.Snapshot(page: page)
        return await Task.detached(priority: .userInitiated) {
            let image = PageRenderer.recognitionImage(snapshot, scale: 3)
            return await OCRService.recognize(image: image, pageSize: snapshot.pageSize)
        }.value
    }
}
