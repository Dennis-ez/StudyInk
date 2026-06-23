import SwiftUI

/// Transparent layer above the ink that draws Claude's annotations — highlights,
/// hand-drawn circles, arrows, underlines — in canvas space with entrance
/// animations. Never intercepts touches and never alters the drawing.
struct AnnotationOverlay: View {
    let annotations: [AIAnnotationModel]
    let bubbleOrigin: CGPoint?
    let transform: CanvasTransform

    @State private var progress: [UUID: CGFloat] = [:]

    var body: some View {
        ZStack {
            ForEach(annotations) { annotation in
                if let rect = annotation.rect {
                    annotationView(annotation, rect: transform.toScreen(rect))
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: annotations.map(\.id)) { animateEntrances() }
        .onAppear { animateEntrances() }
    }

    private func animateEntrances() {
        for annotation in annotations where progress[annotation.id] == nil {
            progress[annotation.id] = 0
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7).delay(0.05)) {
                progress[annotation.id] = 1
            }
        }
    }

    @ViewBuilder
    private func annotationView(_ annotation: AIAnnotationModel, rect: CGRect) -> some View {
        let p = progress[annotation.id] ?? 0
        // Map the AI's semantic token to the active skin's mark colors so the
        // on-page circle/arrow/highlight/underline follow the theme.
        let color: Color = {
            switch annotation.colorToken {
            case "aiCircleStroke":   return AppTheme.current.aiCircleColor
            case "aiHighlightYellow": return AppTheme.current.aiHighlight
            case "aiArrow":          return AppTheme.current.aiArrowColor
            case "accentBlue":       return AppTheme.current.aiUnderlineColor
            default:                 return Color(annotation.colorToken)
            }
        }()

        switch annotation.kind {
        case .highlight:
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: rect.width + 8, height: rect.height + 6)
                .position(x: rect.midX, y: rect.midY)
                .opacity(Double(p))
        case .circle:
            ImperfectCircleShape(seed: annotation.id.hashValue)
                .trim(from: 0, to: p)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: rect.width + 26, height: rect.height + 22)
                .position(x: rect.midX, y: rect.midY)
        case .underline:
            WavyUnderlineShape()
                .trim(from: 0, to: p)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: rect.width + 6, height: 6)
                .position(x: rect.midX, y: rect.maxY + 5)
        case .arrow:
            let from = bubbleOrigin.map { transform.toScreen($0) }
                ?? CGPoint(x: rect.midX - 80, y: rect.midY - 80)
            ArrowShape(from: from, to: CGPoint(x: rect.midX, y: rect.midY - rect.height / 2 - 4))
                .trim(from: 0, to: p)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .ignoresSafeArea()
        }
    }
}

/// A tutor's circle: an ellipse with seeded jitter and an overlapping closing
/// stroke, so it reads as hand-drawn rather than geometric.
struct ImperfectCircleShape: Shape {
    let seed: Int

    func path(in rect: CGRect) -> Path {
        var generator = SeededRandom(seed: UInt64(bitPattern: Int64(seed)))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radiusX = rect.width / 2
        let radiusY = rect.height / 2

        var path = Path()
        let steps = 36
        // Slightly past a full turn so the ends overlap like a real pen circle.
        let totalAngle = 2 * CGFloat.pi * 1.08
        let startAngle = CGFloat.pi * 0.3
        for step in 0...steps {
            let angle = startAngle + totalAngle * CGFloat(step) / CGFloat(steps)
            let wobble = 1 + (generator.next() - 0.5) * 0.09
            let point = CGPoint(
                x: center.x + cos(angle) * radiusX * wobble,
                y: center.y + sin(angle) * radiusY * wobble
            )
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

struct WavyUnderlineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        let waves = max(Int(rect.width / 12), 2)
        let step = rect.width / CGFloat(waves)
        for i in 0..<waves {
            let x = rect.minX + CGFloat(i) * step
            path.addQuadCurve(
                to: CGPoint(x: x + step, y: rect.midY),
                control: CGPoint(x: x + step / 2, y: i.isMultiple(of: 2) ? rect.minY : rect.maxY)
            )
        }
        return path
    }
}

/// Curved arrow from the bubble toward its target, head included in the path so
/// `trim` animates tail → tip.
struct ArrowShape: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let dx = to.x - from.x
        let dy = to.y - from.y
        let control = CGPoint(x: mid.x - dy * 0.18, y: mid.y + dx * 0.18)
        path.addQuadCurve(to: to, control: control)

        // Arrowhead aligned with the curve's terminal direction.
        let angle = atan2(to.y - control.y, to.x - control.x)
        let headLength: CGFloat = 12
        for side in [-1.0, 1.0] {
            let theta = angle + CGFloat(side) * (.pi * 0.82)
            path.move(to: to)
            path.addLine(to: CGPoint(x: to.x + cos(theta) * headLength, y: to.y + sin(theta) * headLength))
        }
        return path
    }
}

/// Deterministic light-weight RNG so each circle keeps its shape across redraws.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> CGFloat {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return CGFloat(state % 10_000) / 10_000
    }
}
