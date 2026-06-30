import Foundation

/// Splits Claude's reply into display text and the trailing structured JSON block
/// (annotations + chips + tone). Tolerates fenced and bare JSON, or none at all.
enum AIResponseParser {
    private struct Payload: Decodable {
        struct Annotation: Decodable {
            let type: String
            let target: String?
            let match_string: String?
            let color: String?
            let box: [Double]?
        }
        let annotations: [Annotation]?
        let chips: [String]?
        let tone: String?
    }

    static func parse(_ raw: String) -> AIParsedResponse {
        let (text, jsonString) = splitTrailingJSON(from: raw)

        var annotations: [AIAnnotationModel] = []
        var chips: [String] = []
        var tone = AIBubbleTone.explanation

        if let jsonString, let data = jsonString.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            annotations = (payload.annotations ?? []).compactMap { item in
                guard let kind = AIAnnotationModel.Kind(rawValue: item.type) else { return nil }
                var annotation = AIAnnotationModel(kind: kind, matchString: item.match_string, colorToken: item.color ?? "")
                annotation.box = item.box
                if annotation.colorToken.isEmpty { annotation.colorToken = annotation.defaultToken }
                return annotation
            }
            chips = (payload.chips ?? []).filter { !$0.isEmpty }
            if let rawTone = payload.tone, let parsed = AIBubbleTone(rawValue: rawTone) {
                tone = parsed
            }
        }

        return AIParsedResponse(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            annotations: annotations,
            chips: chips,
            tone: tone
        )
    }

    /// Finds the last JSON object in the reply — ```json fenced, or a bare trailing
    /// object — and returns (text without it, json string).
    private static func splitTrailingJSON(from raw: String) -> (String, String?) {
        // Fenced block first.
        if let fenceRange = raw.range(of: "```json", options: [.backwards, .caseInsensitive]) {
            let afterFence = raw[fenceRange.upperBound...]
            if let closing = afterFence.range(of: "```") {
                let json = String(afterFence[..<closing.lowerBound])
                var text = String(raw[..<fenceRange.lowerBound])
                text += String(afterFence[closing.upperBound...])
                return (text, json)
            }
        }
        // Bare trailing object: scan back from the end for a balanced {...}.
        guard let lastBrace = raw.lastIndex(of: "}") else { return (raw, nil) }
        var depth = 0
        var index = lastBrace
        while true {
            let char = raw[index]
            if char == "}" { depth += 1 }
            if char == "{" {
                depth -= 1
                if depth == 0 { break }
            }
            if index == raw.startIndex { return (raw, nil) }
            index = raw.index(before: index)
        }
        let candidate = String(raw[index...lastBrace])
        // Only treat it as payload if it actually looks like our schema.
        guard candidate.contains("\"annotations\"") || candidate.contains("\"chips\"") else {
            return (raw, nil)
        }
        return (String(raw[..<index]), candidate)
    }

    /// Resolves each annotation to a precise page rect: prefer the model's normalized
    /// `box` (it SEES the image) mapped through the same content-crop the image used,
    /// else fall back to OCR-line text matching. Either candidate is then SNAPPED to the
    /// actual vector strokes under it — so the mark lands on the handwriting, not a loose
    /// region, and tracks those strokes (erasing the ink clears the mark).
    /// `imageCrop` is the page-space rect the AI's image covered (contentBounds, or the
    /// full page when uncropped). `strokes` are the page's vector strokes, page space.
    static func resolve(annotations: [AIAnnotationModel], lines: [OCRLine],
                        strokes: [VectorInk.Stroke], imageCrop: CGRect) -> [AIAnnotationModel] {
        annotations.map { annotation in
            guard annotation.rect == nil else { return annotation }
            var resolved = annotation
            // 1) Candidate region.
            var candidate: CGRect?
            if let b = annotation.box, b.count == 4, imageCrop.width > 0, imageCrop.height > 0 {
                candidate = CGRect(
                    x: imageCrop.minX + CGFloat(b[0]) * imageCrop.width,
                    y: imageCrop.minY + CGFloat(b[1]) * imageCrop.height,
                    width: max(CGFloat(b[2]) * imageCrop.width, 8),
                    height: max(CGFloat(b[3]) * imageCrop.height, 8)
                )
            } else if let target = annotation.matchString?.normalizedForMatch, !target.isEmpty {
                candidate = ocrRect(for: target, in: lines)
            }
            guard let rect = candidate else { return resolved }
            // 2) Snap to the ink under the candidate (tight union of intersecting strokes).
            let hits = strokes.filter { $0.bbox.intersects(rect) }
            if !hits.isEmpty {
                resolved.rect = hits.dropFirst().reduce(hits[0].bbox) { $0.union($1.bbox) }
                resolved.strokeAnchored = true
            } else {
                resolved.rect = rect
            }
            return resolved
        }
    }

    /// OCR-only convenience (no stroke snapping / box) for callers without page
    /// context. A zero crop disables the box path, so this is pure OCR resolution.
    static func resolve(annotations: [AIAnnotationModel], against lines: [OCRLine]) -> [AIAnnotationModel] {
        resolve(annotations: annotations, lines: lines, strokes: [], imageCrop: .zero)
    }

    /// OCR-line text match → a proportional slice of the line box (page space).
    private static func ocrRect(for target: String, in lines: [OCRLine]) -> CGRect? {
        for line in lines {
            let haystack = line.text.normalizedForMatch
            guard let range = haystack.range(of: target) else { continue }
            let start = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            let length = haystack.distance(from: range.lowerBound, to: range.upperBound)
            let total = max(haystack.count, 1)
            return CGRect(
                x: line.rect.minX + line.rect.width * CGFloat(start) / CGFloat(total),
                y: line.rect.minY,
                width: max(line.rect.width * CGFloat(length) / CGFloat(total), 24),
                height: line.rect.height
            )
        }
        return nil
    }
}

private extension String {
    /// Loosens OCR/LaTeX mismatches: strip spaces and common math decorations.
    var normalizedForMatch: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "·", with: "*")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "\\", with: "")
    }
}
