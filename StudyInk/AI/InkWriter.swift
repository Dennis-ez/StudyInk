import PencilKit
import CoreText
import UIKit

/// Turns text into PencilKit strokes that read like handwriting. Each glyph's
/// outline (from a light hand-style font) is FILLED with closely-spaced thin pen
/// strokes — not traced — so letters and symbols (+, =, √, ∫) render solid like
/// a real pen instead of hollow outlines, while staying thin. The result is real
/// erasable, lassoable, undoable ink. Used by the ambient tutor / Answer in Ink.
enum InkWriter {
    /// Light hand-style face — thin strokes once filled. System fallback covers
    /// math symbols (√, ∫, ², …).
    private static func font(size: CGFloat) -> UIFont {
        UIFont(name: "Noteworthy-Light", size: size)
            ?? UIFont(name: "BradleyHandITCTT-Bold", size: size)
            ?? .italicSystemFont(ofSize: size)
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
    /// `strokeWidth` is unused now (the fill nib is derived from the font size);
    /// kept for source compatibility.
    static func strokes(for text: String, topLeft: CGPoint, fontSize: CGFloat, ink: PKInk, strokeWidth: CGFloat) -> [PKStroke] {
        let font = font(size: fontSize)
        // Thin pen nib; scanlines spaced a touch under it so the fill reads solid.
        let nib = max(1.1, fontSize * 0.05)
        var result: [PKStroke] = []
        for (index, lineText) in text.components(separatedBy: "\n").enumerated() {
            // CoreText draws from the baseline; offset by the ascender.
            let baseline = CGPoint(
                x: topLeft.x,
                y: topLeft.y + font.ascender + CGFloat(index) * lineHeight(fontSize: fontSize)
            )
            result += lineStrokes(lineText, baseline: baseline, font: font, ink: ink, nib: nib)
        }
        return result
    }

    private static func lineStrokes(_ text: String, baseline: CGPoint, font: UIFont, ink: PKInk, nib: CGFloat) -> [PKStroke] {
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
                // Glyph space is y-up around the baseline; map to y-down page space.
                var transform = CGAffineTransform(
                    a: 1, b: 0, c: 0, d: -1,
                    tx: baseline.x + positions[i].x, ty: baseline.y
                )
                guard let placed = glyphPath.copy(using: &transform) else { continue }
                strokes += fillStrokes(for: placed, ink: ink, nib: nib)
            }
        }
        return strokes
    }

    // MARK: - Glyph fill

    /// Scanline-fills a glyph outline: walks horizontal lines down the glyph,
    /// intersects them with the outline, and inks a thin pen stroke between each
    /// entering/leaving pair (even-odd, so counters like 'o'/'8' stay open).
    private static func fillStrokes(for path: CGPath, ink: PKInk, nib: CGFloat) -> [PKStroke] {
        let loops = polylines(from: path).filter { $0.count >= 2 }
        guard !loops.isEmpty else { return [] }

        let box = path.boundingBoxOfPath
        guard box.height > 0.5 else { return [] }

        let spacing = max(0.8, nib * 0.85)
        var strokes: [PKStroke] = []
        var y = box.minY + spacing * 0.5
        while y < box.maxY {
            // X crossings of this scanline with every outline segment.
            var xs: [CGFloat] = []
            for loop in loops {
                let n = loop.count
                for i in 0..<n {
                    let a = loop[i], b = loop[(i + 1) % n]
                    if a.y == b.y { continue }
                    let lo = min(a.y, b.y), hi = max(a.y, b.y)
                    if y >= lo && y < hi {
                        xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                }
            }
            xs.sort()
            var k = 0
            while k + 1 < xs.count {
                // Ink the full span (no inset) so thin stems don't collapse to dots.
                strokes.append(scanlineStroke(x0: xs[k], x1: xs[k + 1], y: y, ink: ink, width: nib))
                k += 2
            }
            y += spacing
        }
        return strokes
    }

    private static func scanlineStroke(x0: CGFloat, x1: CGFloat, y: CGFloat, ink: PKInk, width: CGFloat) -> PKStroke {
        let points = [CGPoint(x: x0, y: y), CGPoint(x: max(x1, x0 + 0.1), y: y)].enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.002,
                size: CGSize(width: width, height: width),
                opacity: 1, force: 1,
                azimuth: 0, altitude: .pi / 2
            )
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
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
}
