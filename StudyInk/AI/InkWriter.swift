import PencilKit
import CoreText
import UIKit

/// Turns a math expression (a LaTeX subset) into PencilKit strokes that read
/// like handwriting: glyph outlines from a light hand face are traced as real
/// strokes, and structure — \frac{}{} stacked over a rule, x^{2} raised, x_{i}
/// lowered, \sqrt{} under a radical — is laid out in 2D so it looks written, not
/// typed (no "a/b" slashes). Erasable / lassoable / undoable like the user's ink.
enum InkWriter {
    /// Light hand-style face — thin natural strokes. System fallback covers math
    /// symbols (√, ∫, ², …).
    private static func font(size: CGFloat) -> UIFont {
        UIFont(name: "Noteworthy-Light", size: size)
            ?? UIFont(name: "BradleyHandITCTT-Bold", size: size)
            ?? .italicSystemFont(ofSize: size)
    }

    static func lineHeight(fontSize: CGFloat) -> CGFloat { fontSize * 1.55 }

    /// Width of the widest line, laid out (a fraction is as wide as its longer
    /// row, not the slash form), for placement decisions.
    static func width(of text: String, fontSize: CGFloat) -> CGFloat {
        text.components(separatedBy: "\n")
            .map { layout(parse($0), fontSize: fontSize).width }
            .max() ?? 0
    }

    /// First line's extents above/below the baseline — lets a caller vertically
    /// centre a tall result (a fraction) on a line instead of hanging below it.
    static func firstLineMetrics(of text: String, fontSize: CGFloat) -> (ascent: CGFloat, descent: CGFloat) {
        let box = layout(parse(text.components(separatedBy: "\n").first ?? ""), fontSize: fontSize)
        return (box.ascent, box.descent)
    }

    /// Renders `text` (multi-line via \n) starting at `topLeft`, page space.
    /// `strokeWidth` traces the glyph outline and draws fraction/radical rules.
    static func strokes(for text: String, topLeft: CGPoint, fontSize: CGFloat, ink: PKInk, strokeWidth: CGFloat) -> [PKStroke] {
        var result: [PKStroke] = []
        var y = topLeft.y
        for lineText in text.components(separatedBy: "\n") {
            let box = layout(parse(lineText), fontSize: fontSize)
            let baseline = CGPoint(x: topLeft.x, y: y + box.ascent)
            result += box.draw(baseline, ink, strokeWidth)
            y += box.ascent + box.descent + fontSize * 0.42
        }
        return result
    }

    // MARK: - Parse (LaTeX subset)

    private indirect enum Node {
        case text(String)
        case row([Node])
        case frac(Node, Node)
        case sqrt(Node)
        case script(base: Node, sup: Node?, sub: Node?)
    }

    private final class Scanner {
        let chars: [Character]; var i = 0
        init(_ s: String) { chars = Array(s) }
        var done: Bool { i >= chars.count }
        func peek() -> Character? { done ? nil : chars[i] }
        @discardableResult func advance() -> Character? { defer { i += 1 }; return done ? nil : chars[i] }
    }

    private static func parse(_ s: String) -> Node { parseRow(Scanner(s), until: nil) }

    /// Readable one-line unicode form of a LaTeX-subset expression, for text
    /// previews (the ink itself is laid out in 2D by `strokes`).
    static func plainText(from latex: String) -> String { render(parse(latex)) }

    private static func render(_ node: Node) -> String {
        switch node {
        case .text(let s): return s
        case .row(let ns): return ns.map(render).joined()
        case .frac(let a, let b): return "\(group(a))/\(group(b))"
        case .sqrt(let x): return "√(\(render(x)))"
        case .script(let base, let sup, let sub):
            var r = render(base)
            if let sub { r += scriptStr(render(sub), sub: true) }
            if let sup { r += scriptStr(render(sup), sub: false) }
            return r
        }
    }

    private static func group(_ node: Node) -> String {
        let s = render(node)
        return s.count > 1 ? "(\(s))" : s
    }

    private static func scriptStr(_ s: String, sub: Bool) -> String {
        let sup: [Character: Character] = ["0":"⁰","1":"¹","2":"²","3":"³","4":"⁴","5":"⁵","6":"⁶","7":"⁷","8":"⁸","9":"⁹","+":"⁺","-":"⁻","n":"ⁿ","i":"ⁱ","(":"⁽",")":"⁾"]
        let low: [Character: Character] = ["0":"₀","1":"₁","2":"₂","3":"₃","4":"₄","5":"₅","6":"₆","7":"₇","8":"₈","9":"₉","+":"₊","-":"₋"]
        let map = sub ? low : sup
        if !s.isEmpty, s.allSatisfy({ map[$0] != nil }) { return String(s.map { map[$0]! }) }
        return sub ? "_(\(s))" : "^(\(s))"
    }

    private static func parseRow(_ sc: Scanner, until: Character?) -> Node {
        var nodes: [Node] = []
        while let c = sc.peek(), c != until {
            if c == "}" && until == nil { break }
            if c == "^" || c == "_" {
                sc.advance()
                let script = parseGroup(sc)
                let base = nodes.popLast() ?? .text("")
                if case .script(let b, let sup, let sub) = base {
                    nodes.append(.script(base: b,
                                         sup: c == "^" ? script : sup,
                                         sub: c == "_" ? script : sub))
                } else {
                    nodes.append(.script(base: base,
                                         sup: c == "^" ? script : nil,
                                         sub: c == "_" ? script : nil))
                }
                continue
            }
            nodes.append(parseAtom(sc))
        }
        return .row(mergeText(nodes))
    }

    /// A `{...}` group, or a single atom.
    private static func parseGroup(_ sc: Scanner) -> Node {
        if sc.peek() == "{" {
            sc.advance()
            let n = parseRow(sc, until: "}")
            if sc.peek() == "}" { sc.advance() }
            return n
        }
        return parseAtom(sc)
    }

    private static func parseAtom(_ sc: Scanner) -> Node {
        guard let c = sc.peek() else { return .text("") }
        if c == "\\" {
            sc.advance()
            var cmd = ""
            while let d = sc.peek(), d.isLetter { cmd.append(d); sc.advance() }
            if cmd.isEmpty {                       // escaped char (\{  \}  \\)
                if let d = sc.advance() { return .text(String(d)) }
                return .text("")
            }
            switch cmd {
            case "frac", "dfrac", "tfrac":
                let a = parseGroup(sc); let b = parseGroup(sc); return .frac(a, b)
            case "sqrt":
                return .sqrt(parseGroup(sc))
            default:
                return .text(symbol(cmd))
            }
        }
        sc.advance()
        return .text(String(c))
    }

    /// Merge consecutive text atoms so a run renders as one glyph pass.
    private static func mergeText(_ nodes: [Node]) -> [Node] {
        var out: [Node] = []
        for n in nodes {
            if case .text(let t) = n, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + t)
            } else { out.append(n) }
        }
        return out
    }

    private static func symbol(_ cmd: String) -> String {
        switch cmd {
        case "cdot": return "·"
        case "times": return "×"
        case "div": return "÷"
        case "pm": return "±"
        case "mp": return "∓"
        case "pi": return "π"
        case "theta": return "θ"
        case "alpha": return "α"
        case "beta": return "β"
        case "lambda": return "λ"
        case "infty": return "∞"
        case "to", "rightarrow": return "→"
        case "Rightarrow", "implies": return "⇒"
        case "neq", "ne": return "≠"
        case "leq", "le": return "≤"
        case "geq", "ge": return "≥"
        case "approx": return "≈"
        case "int": return "∫"
        case "sum": return "Σ"
        case "lim": return "lim"
        case "ln": return "ln"
        case "log": return "log"
        case "sin": return "sin"
        case "cos": return "cos"
        case "tan": return "tan"
        case "left", "right", "!", ",", ";", "quad", "qquad": return ""
        default: return cmd
        }
    }

    // MARK: - Layout

    /// A laid-out node: extents measured from its baseline (ascent up, descent
    /// down), and a draw closure that inks it given the baseline-left origin.
    private struct Box {
        var width: CGFloat
        var ascent: CGFloat
        var descent: CGFloat
        var draw: (_ baselineLeft: CGPoint, _ ink: PKInk, _ lineWidth: CGFloat) -> [PKStroke]
    }

    private static func layout(_ node: Node, fontSize: CGFloat) -> Box {
        switch node {
        case .text(let s):
            return textBox(s, fontSize: fontSize)

        case .row(let nodes):
            let boxes = nodes.map { layout($0, fontSize: fontSize) }
            let width = boxes.reduce(0) { $0 + $1.width }
            let ascent = boxes.map(\.ascent).max() ?? fontSize * 0.7
            let descent = boxes.map(\.descent).max() ?? fontSize * 0.2
            return Box(width: width, ascent: ascent, descent: descent) { origin, ink, lw in
                var strokes: [PKStroke] = []
                var x = origin.x
                for b in boxes {
                    strokes += b.draw(CGPoint(x: x, y: origin.y), ink, lw)
                    x += b.width
                }
                return strokes
            }

        case .frac(let num, let den):
            let f = fontSize * 0.94
            let nb = layout(num, fontSize: f), db = layout(den, fontSize: f)
            let pad = fontSize * 0.16
            let width = max(nb.width, db.width) + 2 * pad
            let gap = fontSize * 0.14
            let axis = fontSize * 0.30            // bar height above baseline
            let ascent = axis + gap + nb.ascent + nb.descent
            let descent = -axis + gap + db.ascent + db.descent
            return Box(width: width, ascent: ascent, descent: max(descent, fontSize * 0.2)) { origin, ink, lw in
                var strokes: [PKStroke] = []
                let barY = origin.y - axis
                // Numerator centred above the rule.
                let nx = origin.x + (width - nb.width) / 2
                let nBaseline = barY - gap - nb.descent
                strokes += nb.draw(CGPoint(x: nx, y: nBaseline), ink, lw)
                // Denominator centred below.
                let dx = origin.x + (width - db.width) / 2
                let dBaseline = barY + gap + db.ascent
                strokes += db.draw(CGPoint(x: dx, y: dBaseline), ink, lw)
                // The fraction rule.
                strokes.append(rule(from: CGPoint(x: origin.x, y: barY),
                                    to: CGPoint(x: origin.x + width, y: barY), ink: ink, width: lw))
                return strokes
            }

        case .sqrt(let inner):
            let ib = layout(inner, fontSize: fontSize)
            let radW = fontSize * 0.55
            let over = fontSize * 0.12
            let width = radW + ib.width + fontSize * 0.1
            let ascent = ib.ascent + over + lineWidthPad(fontSize)
            return Box(width: width, ascent: ascent, descent: ib.descent) { origin, ink, lw in
                var strokes: [PKStroke] = []
                let top = origin.y - ascent + lw
                let bottom = origin.y + ib.descent
                let mid = origin.y + ib.descent * 0.3
                // Radical: short up-tick, down to the bottom, up to the top-left,
                // then the overline across the content.
                let p0 = CGPoint(x: origin.x, y: mid)
                let p1 = CGPoint(x: origin.x + radW * 0.32, y: bottom)
                let p2 = CGPoint(x: origin.x + radW * 0.62, y: top)
                let p3 = CGPoint(x: origin.x + width, y: top)
                strokes.append(stroke(through: [p0, p1, p2, p3], ink: ink, width: lw))
                strokes += ib.draw(CGPoint(x: origin.x + radW, y: origin.y), ink, lw)
                return strokes
            }

        case .script(let base, let sup, let sub):
            let bb = layout(base, fontSize: fontSize)
            let sf = fontSize * 0.66
            let supB = sup.map { layout($0, fontSize: sf) }
            let subB = sub.map { layout($0, fontSize: sf) }
            let scriptW = max(supB?.width ?? 0, subB?.width ?? 0)
            let supRise = bb.ascent * 0.55
            let subDrop = bb.descent * 0.4 + sf * 0.35
            let ascent = max(bb.ascent, supRise + (supB?.ascent ?? 0))
            let descent = max(bb.descent, subDrop + (subB?.descent ?? 0))
            return Box(width: bb.width + scriptW, ascent: ascent, descent: descent) { origin, ink, lw in
                var strokes = bb.draw(origin, ink, lw)
                let sx = origin.x + bb.width
                if let s = supB {
                    strokes += s.draw(CGPoint(x: sx, y: origin.y - supRise), ink, lw)
                }
                if let s = subB {
                    strokes += s.draw(CGPoint(x: sx, y: origin.y + subDrop), ink, lw)
                }
                return strokes
            }
        }
    }

    private static func lineWidthPad(_ fontSize: CGFloat) -> CGFloat { fontSize * 0.08 }

    /// A plain run of glyphs, measured + drawable.
    private static func textBox(_ s: String, fontSize: CGFloat) -> Box {
        let f = font(size: fontSize)
        let w = (s as NSString).size(withAttributes: [.font: f]).width
        // Consistent extents so fractions/scripts align nicely.
        let ascent = f.capHeight > 0 ? f.capHeight : fontSize * 0.7
        let descent = fontSize * 0.2
        return Box(width: w, ascent: ascent, descent: descent) { origin, ink, lw in
            glyphStrokes(s, baselineLeft: origin, font: f, ink: ink, width: lw)
        }
    }

    // MARK: - Glyph rendering (filled)

    /// Glyphs are SOLID, not wireframe: each glyph's outline is both stroked
    /// (crisp edges) and scanline-filled (the interior packed with short
    /// horizontal pen strokes, even-odd so counters like the holes in o/e/0
    /// stay open). Tracing the outline alone left stems as two parallel lines —
    /// the "hollow" look. The fill makes AI ink read like a real pen.
    private static func glyphStrokes(_ text: String, baselineLeft: CGPoint, font: UIFont, ink: PKInk, width: CGFloat) -> [PKStroke] {
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
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont

            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                // All contours of THIS glyph, in page space (y flipped).
                let contours: [[CGPoint]] = polylines(from: glyphPath).compactMap { poly in
                    guard poly.count >= 2 else { return nil }
                    return poly.map { p in
                        CGPoint(x: baselineLeft.x + positions[i].x + p.x, y: baselineLeft.y - p.y)
                    }
                }
                guard !contours.isEmpty else { continue }
                // Crisp edges.
                for contour in contours { strokes.append(stroke(through: contour, ink: ink, width: width)) }
                // Solid interior.
                strokes += fillStrokes(contours: contours, ink: ink, penWidth: width)
            }
        }
        return strokes
    }

    /// Scanline-fill the region bounded by `contours` (even-odd) with short
    /// horizontal pen strokes spaced so they overlap into a solid fill.
    private static func fillStrokes(contours: [[CGPoint]], ink: PKInk, penWidth: CGFloat) -> [PKStroke] {
        let ys = contours.flatMap { $0.map(\.y) }
        guard let minY = ys.min(), let maxY = ys.max(), maxY - minY > penWidth else { return [] }
        let spacing = max(0.9, penWidth * 0.7)
        var strokes: [PKStroke] = []
        var y = minY + spacing * 0.5
        while y < maxY {
            // x-crossings of the scanline with every edge (incl. closing edge).
            var xs: [CGFloat] = []
            for poly in contours {
                let n = poly.count
                for k in 0..<n {
                    let a = poly[k], b = poly[(k + 1) % n]
                    if (a.y <= y && b.y > y) || (b.y <= y && a.y > y) {
                        xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                }
            }
            xs.sort()
            var j = 0
            while j + 1 < xs.count {
                if xs[j + 1] - xs[j] > 0.2 {
                    strokes.append(stroke(
                        through: [CGPoint(x: xs[j], y: y), CGPoint(x: xs[j + 1], y: y)],
                        ink: ink, width: spacing * 1.3))
                }
                j += 2
            }
            y += spacing
        }
        return strokes
    }

    /// Horizontal rule (fraction bar) as a single stroke.
    private static func rule(from a: CGPoint, to b: CGPoint, ink: PKInk, width: CGFloat) -> PKStroke {
        stroke(through: [a, b], ink: ink, width: width)
    }

    // MARK: - Path flattening

    private static func polylines(from path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last = CGPoint.zero

        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count >= 2 { result.append(current) }
                current = [e.points[0]]; last = e.points[0]
            case .addLineToPoint:
                current.append(e.points[0]); last = e.points[0]
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
