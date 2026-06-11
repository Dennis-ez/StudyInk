import PencilKit
import CoreText
import UIKit

/// Turns text into PencilKit strokes that read like handwriting: each glyph's
/// outline (from a hand-style font) is flattened into polylines and inked as
/// real strokes — erasable, lassoable, undoable, exported like the user's own
/// ink. Used by "Answer in Ink" to write AI answers onto the page.
enum InkWriter {
    /// Hand-style font with system fallback for math symbols (√, ∫, ², …).
    private static func font(size: CGFloat) -> UIFont {
        UIFont(name: "BradleyHandITCTT-Bold", size: size) ?? .italicSystemFont(ofSize: size)
    }

    static func lineHeight(fontSize: CGFloat) -> CGFloat { fontSize * 1.4 }

    /// Widest line of `text` at the given size, for placement decisions.
    static func width(of text: String, fontSize: CGFloat) -> CGFloat {
        let font = font(size: fontSize)
        return text.components(separatedBy: "\n")
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
    }

    /// Renders `text` (multi-line via \n) starting at `topLeft`, page space.
    static func strokes(for text: String, topLeft: CGPoint, fontSize: CGFloat, ink: PKInk, strokeWidth: CGFloat) -> [PKStroke] {
        let font = font(size: fontSize)
        var result: [PKStroke] = []
        for (index, lineText) in text.components(separatedBy: "\n").enumerated() {
            // CoreText draws from the baseline; offset by the ascender.
            let baseline = CGPoint(
                x: topLeft.x,
                y: topLeft.y + font.ascender + CGFloat(index) * lineHeight(fontSize: fontSize)
            )
            result += lineStrokes(lineText, baseline: baseline, font: font, ink: ink, strokeWidth: strokeWidth)
        }
        return result
    }

    private static func lineStrokes(_ text: String, baseline: CGPoint, font: UIFont, ink: PKInk, strokeWidth: CGFloat) -> [PKStroke] {
        guard !text.isEmpty else { return [] }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }

        var strokes: [PKStroke] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            // Respect per-run fallback fonts — math symbols don't live in the
            // hand font, and glyph IDs only mean anything in their own font.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont

            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                for polyline in polylines(from: glyphPath) {
                    // Glyph space is y-up around the baseline; page space is y-down.
                    let points = polyline.map { point in
                        CGPoint(
                            x: baseline.x + positions[i].x + point.x,
                            y: baseline.y - point.y
                        )
                    }
                    guard points.count >= 2 else { continue }
                    strokes.append(stroke(through: points, ink: ink, width: strokeWidth))
                }
            }
        }
        return strokes
    }

    // MARK: - Path flattening

    /// One polyline per subpath, curves sampled into short segments.
    private static func polylines(from path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last = CGPoint.zero

        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count >= 2 { result.append(current) }
                current = [e.points[0]]
                last = e.points[0]
            case .addLineToPoint:
                current.append(e.points[0])
                last = e.points[0]
            case .addQuadCurveToPoint:
                let control = e.points[0], end = e.points[1]
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    let a = lerp(last, control, t), b = lerp(control, end, t)
                    current.append(lerp(a, b, t))
                }
                last = end
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], end = e.points[2]
                for step in 1...10 {
                    let t = CGFloat(step) / 10
                    let a = lerp(last, c1, t), b = lerp(c1, c2, t), c = lerp(c2, end, t)
                    let ab = lerp(a, b, t), bc = lerp(b, c, t)
                    current.append(lerp(ab, bc, t))
                }
                last = end
            case .closeSubpath:
                if let first = current.first { current.append(first) }
                if current.count >= 2 { result.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if current.count >= 2 { result.append(current) }
        return result
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func stroke(through points: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
        let controlPoints = points.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.004,
                size: CGSize(width: width, height: width),
                opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
    }
}
