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

    static func drawStroke(_ pts: [InkSample], color: UIColor, in ctx: CGContext) {
        guard pts.count > 1 else {
            if let p = pts.first {
                ctx.setFillColor(color.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.location.x - p.width / 2, y: p.location.y - p.width / 2,
                                           width: p.width, height: p.width))
            }
            return
        }
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(avgWidth(pts))
        ctx.addPath(inkPath(pts))
        ctx.strokePath()
    }

    // MARK: PencilKit → vector strokes

    /// Convert a `PKDrawing` to vector strokes by sampling each stroke's interpolated
    /// path (location + width) and taking the ink colour as-is. Pass an already
    /// appearance-adapted drawing if you want dark-mode colours baked in.
    static func strokes(from drawing: PKDrawing) -> [Stroke] {
        drawing.strokes.compactMap { stroke -> Stroke? in
            let t = stroke.transform
            func sample(_ p: PKStrokePoint) -> InkSample {
                // Clamp width so a thin/zero-size stroke can't render invisibly.
                InkSample(location: p.location.applying(t), width: max(p.size.width, p.size.height, 1))
            }
            var samples = stroke.path.interpolatedPoints(by: .distance(1.5)).map(sample)
            // Short strokes can interpolate to < 2 points → fall back to the raw
            // control points so no stroke is ever dropped.
            if samples.count < 2 { samples = stroke.path.map(sample) }
            guard !samples.isEmpty else { return nil }
            return Stroke(color: stroke.ink.color, samples: samples)
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
