import CoreGraphics

/// Snap grid derived from a page's template: ruled papers snap vertically to
/// their lines, grids snap on both axes, blank/PDF/staff pages don't snap.
/// Values are magnetic — they only snap when already close to a line.
struct SnapMetrics {
    var stepX: CGFloat?
    var stepY: CGFloat?

    static func metrics(for template: PageTemplate, spacing: CGFloat) -> SnapMetrics? {
        let s = max(spacing, 0.4)
        switch template {
        case .wideRuled: return SnapMetrics(stepX: nil, stepY: 34 * s)
        case .collegeRuled, .cornell: return SnapMetrics(stepX: nil, stepY: 26 * s)
        case .narrowRuled: return SnapMetrics(stepX: nil, stepY: 20 * s)
        case .dotGrid, .squareGrid: return SnapMetrics(stepX: 24 * s, stepY: 24 * s)
        case .blank, .customPDF, .isometricGrid, .musicStaff: return nil
        }
    }

    /// Nearest line if within the magnetic threshold, else the raw value.
    static func snap(_ value: CGFloat, step: CGFloat?) -> CGFloat {
        guard let step, step > 4 else { return value }
        let nearest = (value / step).rounded() * step
        return abs(nearest - value) <= min(step * 0.35, 12) ? nearest : value
    }

    func snappedX(_ value: CGFloat) -> CGFloat { Self.snap(value, step: stepX) }
    func snappedY(_ value: CGFloat) -> CGFloat { Self.snap(value, step: stepY) }

    func snappedPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: snappedX(point.x), y: snappedY(point.y))
    }

    /// Snaps each edge independently, refusing degenerate results.
    func snappedRect(_ rect: CGRect, minSize: CGFloat = 24) -> CGRect {
        let minX = snappedX(rect.minX)
        let maxX = snappedX(rect.maxX)
        let minY = snappedY(rect.minY)
        let maxY = snappedY(rect.maxY)
        guard maxX - minX >= minSize, maxY - minY >= minSize else { return rect }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
