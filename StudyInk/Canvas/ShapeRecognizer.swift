import PencilKit
import UIKit

/// Recognizes a hand-drawn stroke as a clean geometric shape (Apple-Notes
/// style "snap after a beat"): straight lines, circles/ellipses, triangles,
/// rectangles, and general polygons up to six corners.
enum ShapeRecognizer {
    enum Shape: Equatable {
        case line(from: CGPoint, to: CGPoint)
        case ellipse(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat)
        case polygon([CGPoint])   // closed, ordered corners
    }

    // MARK: - Recognition

    static func recognize(_ stroke: PKStroke) -> Shape? {
        recognize(points: sample(stroke))
    }

    /// Core recognizer over raw points — also used for in-flight (pencil still
    /// touching) detection where no PKStroke exists yet.
    static func recognize(points: [CGPoint]) -> Shape? {
        guard points.count >= 10 else { return nil }
        let box = boundingBox(points)
        let diagonal = hypot(box.width, box.height)
        guard diagonal > 40 else { return nil }

        let gapToClose = distance(points[0], points[points.count - 1])
        let closed = gapToClose < max(24, diagonal * 0.18)

        if !closed {
            return lineFit(points, diagonal: diagonal)
        }

        // Corners via Ramer–Douglas–Peucker; a smooth loop yields many corners,
        // a deliberate polygon yields 3–6.
        let epsilon = max(7, diagonal * 0.05)
        var corners = ramerDouglasPeucker(points, epsilon: epsilon)
        if corners.count > 1, distance(corners[0], corners[corners.count - 1]) < epsilon * 2 {
            corners.removeLast()
        }
        if (3...6).contains(corners.count),
           hugsPolygon(points, corners: corners, tolerance: epsilon * 1.6) {
            // A circle RDPs into 4–6 shallow pseudo-corners that still hug
            // their own outline, so it used to win as a polygon. When the
            // points also fit an ellipse tightly, the ellipse is what the
            // user meant — real rectangles/triangles fail this fit by a mile.
            if corners.count >= 4, let ellipse = ellipseFit(points, box: box, maxError: 0.12) {
                return ellipse
            }
            return .polygon(snapCorners(corners))
        }

        return ellipseFit(points, box: box)
    }

    /// Aligns recognized geometry with the page's template lines/grid.
    /// Snapping must never collapse a small shape into (near-)invisible
    /// geometry — degenerate results fall back to the unsnapped shape.
    static func snapped(_ shape: Shape, to metrics: SnapMetrics) -> Shape {
        let result = snappedUnchecked(shape, to: metrics)
        switch result {
        case .line(let from, let to):
            return distance(from, to) < 16 ? shape : result
        case .polygon(let corners):
            let box = boundingBox(corners)
            return hypot(box.width, box.height) < 24 ? shape : result
        case .ellipse(_, let rx, let ry):
            return (rx < 8 || ry < 8) ? shape : result
        }
    }

    private static func snappedUnchecked(_ shape: Shape, to metrics: SnapMetrics) -> Shape {
        switch shape {
        case .line(let from, let to):
            return .line(from: metrics.snappedPoint(from), to: metrics.snappedPoint(to))
        case .polygon(let corners):
            return .polygon(corners.map(metrics.snappedPoint))
        case .ellipse(let center, let rx, let ry):
            let box = CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
            let snappedBox = metrics.snappedRect(box)
            let wasCircle = abs(rx - ry) < 0.5
            var newRX = snappedBox.width / 2
            var newRY = snappedBox.height / 2
            if wasCircle {
                // Keep circles circular even when only one axis snapped.
                let r = min(newRX, newRY)
                newRX = r
                newRY = r
            }
            return .ellipse(
                center: CGPoint(x: snappedBox.midX, y: snappedBox.midY),
                radiusX: newRX,
                radiusY: newRY
            )
        }
    }

    // MARK: - Ideal stroke construction

    /// Rebuilds the stroke along the ideal geometry, keeping the original ink
    /// and average width so the snap doesn't change the pen's character.
    static func idealStroke(for shape: Shape, like stroke: PKStroke) -> PKStroke {
        idealStroke(for: shape, ink: stroke.ink, pointSize: averagePointSize(of: stroke))
    }

    /// Variant for in-flight detection (no committed stroke to copy from).
    static func idealStroke(for shape: Shape, ink: PKInk, width: CGFloat) -> PKStroke {
        idealStroke(for: shape, ink: ink, pointSize: CGSize(width: max(width, 1), height: max(width, 1)))
    }

    private static func idealStroke(for shape: Shape, ink: PKInk, pointSize: CGSize) -> PKStroke {
        var path: [CGPoint] = []
        switch shape {
        case .line(let from, let to):
            path = densify([from, to], closed: false)
        case .polygon(let corners):
            path = densify(corners, closed: true)
        case .ellipse(let center, let rx, let ry):
            path = (0...72).map { step in
                let angle = CGFloat(step) / 72 * 2 * .pi
                return CGPoint(x: center.x + rx * cos(angle), y: center.y + ry * sin(angle))
            }
        }

        let controlPoints = path.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: TimeInterval(index) * 0.01,
                size: pointSize,
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: controlPoints, creationDate: Date()))
    }

    // MARK: - Fits

    private static func lineFit(_ points: [CGPoint], diagonal: CGFloat) -> Shape? {
        guard let first = points.first, let last = points.last else { return nil }
        let chord = distance(first, last)
        guard chord > 36 else { return nil }
        let maxDeviation = points.map { perpendicularDistance($0, first, last) }.max() ?? 0
        guard maxDeviation < max(5, chord * 0.035) else { return nil }

        // Snap near-horizontal / near-vertical lines exactly.
        var from = first, to = last
        let angle = abs(atan2(to.y - from.y, to.x - from.x)) * 180 / .pi
        if angle < 6 || angle > 174 {
            let y = (from.y + to.y) / 2
            from.y = y; to.y = y
        } else if abs(angle - 90) < 6 {
            let x = (from.x + to.x) / 2
            from.x = x; to.x = x
        }
        return .line(from: from, to: to)
    }

    private static func ellipseFit(_ points: [CGPoint], box: CGRect, maxError: CGFloat = 0.22) -> Shape? {
        let center = CGPoint(x: box.midX, y: box.midY)
        let rx = box.width / 2, ry = box.height / 2
        guard rx > 14, ry > 14 else { return nil }
        var totalError: CGFloat = 0
        for point in points {
            let nx = (point.x - center.x) / rx
            let ny = (point.y - center.y) / ry
            totalError += abs(nx * nx + ny * ny - 1)
        }
        guard totalError / CGFloat(points.count) < maxError else { return nil }
        // Near-round ellipses snap to true circles.
        if abs(rx - ry) / max(rx, ry) < 0.18 {
            let r = (rx + ry) / 2
            return .ellipse(center: center, radiusX: r, radiusY: r)
        }
        return .ellipse(center: center, radiusX: rx, radiusY: ry)
    }

    /// Every sampled point must sit close to the candidate polygon's outline —
    /// rejects smooth blobs that happen to RDP down to few corners.
    private static func hugsPolygon(_ points: [CGPoint], corners: [CGPoint], tolerance: CGFloat) -> Bool {
        for point in points {
            var best = CGFloat.greatestFiniteMagnitude
            for i in corners.indices {
                let a = corners[i], b = corners[(i + 1) % corners.count]
                best = min(best, perpendicularDistance(point, a, b, clampToSegment: true))
                if best < tolerance { break }
            }
            if best > tolerance { return false }
        }
        return true
    }

    /// Rectangles drawn roughly axis-aligned snap to their perfect bounding box.
    private static func snapCorners(_ corners: [CGPoint]) -> [CGPoint] {
        guard corners.count == 4 else { return corners }
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % 4]
            let angle = abs(atan2(b.y - a.y, b.x - a.x)) * 180 / .pi
            let axisAligned = angle < 14 || angle > 166 || abs(angle - 90) < 14
            if !axisAligned { return corners }
        }
        let box = boundingBox(corners)
        return [
            CGPoint(x: box.minX, y: box.minY),
            CGPoint(x: box.maxX, y: box.minY),
            CGPoint(x: box.maxX, y: box.maxY),
            CGPoint(x: box.minX, y: box.maxY),
        ]
    }

    // MARK: - Geometry plumbing

    private static func sample(_ stroke: PKStroke) -> [CGPoint] {
        let path = stroke.path
        let step = max(1, path.count / 160)
        var points: [CGPoint] = []
        for i in stride(from: 0, to: path.count, by: step) {
            points.append(path[i].location.applying(stroke.transform))
        }
        if let last = path.last {
            points.append(last.location.applying(stroke.transform))
        }
        return points
    }

    private static func averagePointSize(of stroke: PKStroke) -> CGSize {
        let path = stroke.path
        guard path.count > 0 else { return CGSize(width: 4, height: 4) }
        let step = max(1, path.count / 16)
        var total = CGSize.zero
        var count: CGFloat = 0
        for i in stride(from: 0, to: path.count, by: step) {
            total.width += path[i].size.width
            total.height += path[i].size.height
            count += 1
        }
        return CGSize(width: total.width / count, height: total.height / count)
    }

    /// Dense points along edges (with tripled corner points) so PencilKit's
    /// spline interpolation keeps corners sharp and edges straight.
    private static func densify(_ corners: [CGPoint], closed: Bool) -> [CGPoint] {
        var output: [CGPoint] = []
        let loop = closed ? corners + [corners[0]] : corners
        for i in 0..<(loop.count - 1) {
            let a = loop[i], b = loop[i + 1]
            output.append(contentsOf: [a, a, a])
            let length = distance(a, b)
            let steps = max(2, Int(length / 6))
            for s in 1..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                output.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        if let last = loop.last { output.append(contentsOf: [last, last, last]) }
        return output
    }

    private static func ramerDouglasPeucker(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var maxDistance: CGFloat = 0
        var index = 0
        for i in 1..<(points.count - 1) {
            let d = perpendicularDistance(points[i], points[0], points[points.count - 1])
            if d > maxDistance {
                maxDistance = d
                index = i
            }
        }
        if maxDistance > epsilon {
            let left = ramerDouglasPeucker(Array(points[0...index]), epsilon: epsilon)
            let right = ramerDouglasPeucker(Array(points[index...]), epsilon: epsilon)
            return left.dropLast() + right
        }
        return [points[0], points[points.count - 1]]
    }

    private static func perpendicularDistance(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint, clampToSegment: Bool = false) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else { return distance(point, a) }
        var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared
        if clampToSegment { t = min(max(t, 0), 1) }
        let projection = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return distance(point, projection)
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = min(minX, p.x); minY = min(minY, p.y)
            maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
