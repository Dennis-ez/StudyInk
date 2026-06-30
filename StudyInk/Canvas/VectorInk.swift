import UIKit
import PencilKit

/// Shared vector-ink model, geometry, and rendering — the reusable core of the
/// custom ink engine (the lab `VectorInkView` is the interactive surface; this is
/// the headless renderer used to integrate the engine into the real app behind the
/// `settings.canvas.customInk` flag).
///
/// Phase 0/1 of the integration plan (DesignHandoff/Custom-Ink-Engine-Integration-Plan.md):
/// convert a `PKDrawing` to vector strokes and rasterise them ourselves, so we can
/// swap the renderer in (e.g. for inactive-page images) with zero input/data risk.
struct InkSample {
    let location: CGPoint
    let width: CGFloat
}

enum VectorInk {

    struct Stroke {
        let color: UIColor
        let samples: [InkSample]
        let bbox: CGRect        // cached for tile culling / erase broad-phase
        init(color: UIColor, samples: [InkSample]) {
            self.color = color
            self.samples = samples
            var r = samples.first.map { CGRect(origin: $0.location, size: .zero) } ?? .null
            for s in samples { r = r.union(CGRect(origin: s.location, size: .zero)) }
            let w = samples.map(\.width).max() ?? 3
            self.bbox = r.isNull ? .null : r.insetBy(dx: -w, dy: -w)
        }
    }

    // MARK: Persistence — compact, versioned, Codable

    /// On-disk form: colour as RGBA, samples flattened to [x,y,w,…] for compactness.
    private struct PersistedDoc: Codable {
        var version = 1
        var strokes: [PersistedStroke]
    }
    private struct PersistedStroke: Codable {
        let c: [CGFloat]      // r,g,b,a
        let p: [CGFloat]      // x,y,w, x,y,w, …
    }

    static func encode(_ strokes: [Stroke]) -> Data? {
        let doc = PersistedDoc(strokes: strokes.map { s in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            s.color.getRed(&r, green: &g, blue: &b, alpha: &a)
            var flat: [CGFloat] = []
            flat.reserveCapacity(s.samples.count * 3)
            for k in s.samples { flat.append(k.location.x); flat.append(k.location.y); flat.append(k.width) }
            return PersistedStroke(c: [r, g, b, a], p: flat)
        })
        return try? JSONEncoder().encode(doc)
    }

    static func decode(_ data: Data) -> [Stroke]? {
        guard let doc = try? JSONDecoder().decode(PersistedDoc.self, from: data) else { return nil }
        return doc.strokes.map { ps in
            let c = ps.c.count >= 4 ? ps.c : [0, 0, 0, 1]
            let color = UIColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
            var samples: [InkSample] = []
            samples.reserveCapacity(ps.p.count / 3)
            var i = 0
            while i + 2 < ps.p.count {
                samples.append(InkSample(location: CGPoint(x: ps.p[i], y: ps.p[i + 1]), width: ps.p[i + 2]))
                i += 3
            }
            return Stroke(color: color, samples: samples)
        }
    }

    // MARK: Geometry (identical to the lab's wet/committed rendering — WYSIWYG)

    /// ONE width for the whole stroke (matches the lab's wet preview).
    static func avgWidth(_ pts: [InkSample]) -> CGFloat {
        guard !pts.isEmpty else { return 2.6 }
        return pts.reduce(0) { $0 + $1.width } / CGFloat(pts.count)
    }

    /// Midpoint-smoothed centerline.
    static func inkPath(_ pts: [InkSample]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count > 1 else {
            if let p = pts.first {
                path.addEllipse(in: CGRect(x: p.location.x - p.width / 2, y: p.location.y - p.width / 2,
                                           width: p.width, height: p.width))
            }
            return path
        }
        path.move(to: pts[0].location)
        for i in 1..<pts.count {
            let a = pts[i - 1].location, b = pts[i].location
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            path.addQuadCurve(to: mid, control: a)
            path.addLine(to: b)
        }
        return path
    }

    /// A FILLED outline whose half-width follows EACH sample's width — true
    /// variable-width ink (pressure/velocity taper), versus stroking one avg width.
    /// The centerline is assumed already smoothed (dense samples → smooth edges); the
    /// two ends get round caps. Constant widths render as a constant band, so this is
    /// safe for every pen — only the fountain feeds it varying widths.
    static func variableWidthOutline(_ pts: [InkSample]) -> CGPath {
        let path = CGMutablePath()
        guard pts.count >= 2 else {
            if let p = pts.first {
                let w = max(0.4, p.width)
                path.addEllipse(in: CGRect(x: p.location.x - w / 2, y: p.location.y - w / 2, width: w, height: w))
            }
            return path
        }
        func unitNormal(_ i: Int) -> (CGFloat, CGFloat) {
            let a = pts[max(0, i - 1)].location, b = pts[min(pts.count - 1, i + 1)].location
            let dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            guard len > 0.0001 else { return (0, 0) }
            return (-dy / len, dx / len)
        }
        var left = [CGPoint](), right = [CGPoint]()
        left.reserveCapacity(pts.count); right.reserveCapacity(pts.count)
        for i in pts.indices {
            let p = pts[i].location, hw = max(0.2, pts[i].width / 2)
            let (nx, ny) = unitNormal(i)
            left.append(CGPoint(x: p.x + nx * hw, y: p.y + ny * hw))
            right.append(CGPoint(x: p.x - nx * hw, y: p.y - ny * hw))
        }
        path.move(to: left[0])
        for i in 1..<left.count { path.addLine(to: left[i]) }
        for i in stride(from: right.count - 1, through: 0, by: -1) { path.addLine(to: right[i]) }
        path.closeSubpath()
        // Round caps as circles at the two ends, unioned with the band (.winding fill).
        for end in [pts[0], pts[pts.count - 1]] {
            let w = max(0.4, end.width)
            path.addEllipse(in: CGRect(x: end.location.x - w / 2, y: end.location.y - w / 2, width: w, height: w))
        }
        return path
    }

    static func drawStroke(_ pts: [InkSample], color: UIColor, in ctx: CGContext) {
        guard pts.count > 1 else {
            if let p = pts.first {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.location.x - p.width / 2, y: p.location.y - p.width / 2,
                                           width: p.width, height: p.width))
            }
            return
        }
        ctx.setFillColor(color.cgColor)
        ctx.addPath(variableWidthOutline(pts))
        ctx.fillPath()
    }

    // MARK: PencilKit → vector strokes

    /// Convert a `PKDrawing` to vector strokes by sampling each stroke's interpolated
    /// path (location + width) and taking the ink colour as-is. Pass an already
    /// appearance-adapted drawing if you want dark-mode colours baked in.
    /// PencilKit's pressure pens TAPER (thin at the ends, pressure-varied), so a
    /// CONSTANT-width stroke at the same nominal size reads much heavier — the app
    /// itself scales constant-width monoline ink by 0.38 for exactly this reason
    /// (see DrawingTool.inkTool). We render constant width, so apply the same kind of
    /// compensation or converted ink comes out ~2× too thick. Tunable.
    static let penWeight: CGFloat = 0.55

    static func strokes(from drawing: PKDrawing) -> [Stroke] {
        drawing.strokes.compactMap { stroke -> Stroke? in
            let t = stroke.transform
            func sample(_ p: PKStrokePoint) -> InkSample {
                let footprint = (p.size.width + p.size.height) / 2
                // Floor so a thin/zero-size stroke can't render invisibly.
                return InkSample(location: p.location.applying(t), width: max(footprint * penWeight, 0.4))
            }
            var samples = stroke.path.interpolatedPoints(by: .distance(1.5)).map(sample)
            // Short strokes can interpolate to < 2 points → fall back to the raw
            // control points so no stroke is ever dropped.
            if samples.count < 2 { samples = stroke.path.map(sample) }
            guard !samples.isEmpty else { return nil }
            return Stroke(color: stroke.ink.color, samples: samples)
        }
    }

    // MARK: vector strokes → PencilKit (the interop projection)

    /// Build a `PKDrawing` from vector strokes — the projection written to
    /// `Page.drawingData` so OCR / export / AI-vision (which read the PKDrawing blob)
    /// keep working when the engine owns the live canvas. Colour is taken as-is
    /// (pass canonical/storage colours, same convention as user ink).
    static func pkDrawing(from strokes: [Stroke]) -> PKDrawing {
        let pk = strokes.compactMap { s -> PKStroke? in
            guard !s.samples.isEmpty else { return nil }
            let pts = s.samples.enumerated().map { i, k in
                PKStrokePoint(location: k.location, timeOffset: Double(i) * 0.01,
                              size: CGSize(width: max(k.width, 1), height: max(k.width, 1)),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let path = PKStrokePath(controlPoints: pts, creationDate: Date())
            return PKStroke(ink: PKInk(.pen, color: s.color), path: path)
        }
        return PKDrawing(strokes: pk)
    }

    /// Give strokes a natural pen taper — thin at the ends (where a real pen lands and
    /// lifts), full width through the middle. Used for AI-written ink so it reads
    /// hand-drawn rather than a blunt constant-width trace. Closed loops (o, 0, circles)
    /// are left alone so the join doesn't pinch.
    static func tapered(_ strokes: [Stroke]) -> [Stroke] {
        strokes.map { s in
            let n = s.samples.count
            guard n >= 5 else { return s }
            let first = s.samples[0].location, last = s.samples[n - 1].location
            let endGap = hypot(first.x - last.x, first.y - last.y)
            // Closed if the trace returns near its start (relative to its own extent).
            let extent = max(s.bbox.width, s.bbox.height)
            if endGap < extent * 0.22 { return s }
            let ramp: CGFloat = 0.16   // taper over the first/last 16% of the stroke
            let floor: CGFloat = 0.42  // never thinner than 42% of full width
            let samples = s.samples.enumerated().map { i, k -> InkSample in
                let t = CGFloat(i) / CGFloat(n - 1)
                let edge = min(t, 1 - t)
                let f = max(floor, min(1, edge / ramp))
                return InkSample(location: k.location, width: k.width * f)
            }
            return Stroke(color: s.color, samples: samples)
        }
    }

    // MARK: Rasterise

    /// Render strokes to a transparent image of `size` at `scale`. Safe OFF the main
    /// thread (unlike `PKDrawing.image()` which the iOS 26 SDK blanks off-main).
    static func image(_ strokes: [Stroke], size: CGSize, scale: CGFloat) -> UIImage? {
        guard !strokes.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = scale
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            for s in strokes { drawStroke(s.samples, color: s.color, in: ctx.cgContext) }
        }
    }
}
