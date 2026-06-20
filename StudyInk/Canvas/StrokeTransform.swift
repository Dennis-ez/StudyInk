import SwiftUI
import PencilKit

/// A lasso-captured set of strokes mid-transform.
struct StrokeSelection {
    var pageIndex: Int
    var strokeIndices: [Int]
    /// Union of the selected strokes' render bounds, page space.
    var bounds: CGRect
    /// The selected strokes rendered alone, for the live rotation preview.
    var image: UIImage
}

enum StrokeSelector {
    /// Strokes with at least one path point inside the lasso polygon (page space).
    static func indices(in drawing: PKDrawing, polygon: [CGPoint]) -> [Int] {
        guard polygon.count > 3 else { return [] }
        return drawing.strokes.enumerated().compactMap { index, stroke in
            let path = stroke.path
            let step = max(1, path.count / 24)
            for i in stride(from: 0, to: path.count, by: step) {
                let point = path[i].location.applying(stroke.transform)
                if contains(polygon: polygon, point: point) { return index }
            }
            return nil
        }
    }

    static func selection(from drawing: PKDrawing, polygon: [CGPoint], pageIndex: Int, darkMode: Bool) -> StrokeSelection? {
        let indices = self.indices(in: drawing, polygon: polygon)
        guard !indices.isEmpty else { return nil }
        let strokes = indices.map { drawing.strokes[$0] }
        let bounds = strokes.dropFirst().reduce(strokes[0].renderBounds) { $0.union($1.renderBounds) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let traits = UITraitCollection(userInterfaceStyle: darkMode ? .dark : .light)
        var image = UIImage()
        traits.performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: bounds, scale: 2)
        }
        return StrokeSelection(pageIndex: pageIndex, strokeIndices: indices, bounds: bounds, image: image)
    }

    /// Ray-casting point-in-polygon.
    static func contains(polygon: [CGPoint], point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// Bakes a scale + rotation (both about the selection's center) AND a
    /// page-space translation into the strokes — one seamless move/resize/rotate.
    static func applyTransform(rotation degrees: Double, scale: CGFloat, translation: CGSize, selection: StrokeSelection, to drawing: PKDrawing) -> PKDrawing {
        let center = CGPoint(x: selection.bounds.midX, y: selection.bounds.midY)
        let combined = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: degrees * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(translationX: translation.width, y: translation.height))
        var result = drawing
        for index in selection.strokeIndices where result.strokes.indices.contains(index) {
            result.strokes[index].transform = result.strokes[index].transform.concatenating(combined)
        }
        return result
    }
}

/// Lasso capture: draw a loop (or, in rectangular mode, drag a marquee) and get
/// its page-space polygon. The free/rectangle shape comes from the toolbar
/// (LassoOptionsStrip) — no on-canvas toast. Tap off to cancel.
struct TransformLassoOverlay: View {
    @Binding var isActive: Bool
    let transform: CanvasTransform
    /// false = freeform loop; true = drag-a-rectangle marquee (from the toolbar).
    let rectangular: Bool
    var onComplete: ([CGPoint]) -> Void

    @State private var points: [CGPoint] = []
    @State private var marquee: CGRect?

    var body: some View {
        if isActive {
            ZStack {
                Color.black.opacity(0.04).ignoresSafeArea()
                if rectangular {
                    if let marquee {
                        Path(marquee)
                            .stroke(SemanticColor.aiCircleStroke, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5]))
                            .background(Path(marquee).fill(SemanticColor.aiCircleStroke.opacity(0.06)))
                    }
                } else {
                    Path { path in
                        guard let first = points.first else { return }
                        path.move(to: first)
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(SemanticColor.aiCircleStroke, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5]))
                }
            }
            .contentShape(Rectangle())
            // A plain tap (no loop) cancels — e.g. tapping off the page or on UI.
            .onTapGesture { points = []; marquee = nil; isActive = false }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if rectangular {
                            marquee = CGRect(
                                x: min(value.startLocation.x, value.location.x),
                                y: min(value.startLocation.y, value.location.y),
                                width: abs(value.location.x - value.startLocation.x),
                                height: abs(value.location.y - value.startLocation.y)
                            )
                        } else {
                            points.append(value.location)
                        }
                    }
                    .onEnded { _ in
                        let polygon: [CGPoint]
                        if let rect = marquee, rectangular {
                            polygon = [
                                CGPoint(x: rect.minX, y: rect.minY),
                                CGPoint(x: rect.maxX, y: rect.minY),
                                CGPoint(x: rect.maxX, y: rect.maxY),
                                CGPoint(x: rect.minX, y: rect.maxY),
                            ].map(transform.toPage)
                        } else {
                            polygon = points.map(transform.toPage)
                        }
                        points = []
                        marquee = nil
                        isActive = false
                        onComplete(polygon)
                    }
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    points = []
                    marquee = nil
                    isActive = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .padding()
                }
                .accessibilityLabel(Text("action.cancel"))
            }
            .transition(.opacity)
        }
    }
}

/// Apple-style transform for a captured selection: drag to move, twist with
/// TWO fingers to rotate, drag a corner handle to resize. Tap off the selection
/// commits; no anchor/rotation handle, no toolbar of buttons.
struct StrokeTransformOverlay: View {
    let selection: StrokeSelection
    let transform: CanvasTransform
    @Binding var rotation: Double
    /// Screen-space drag offset of the selection (→ page space on commit).
    @Binding var translation: CGSize
    /// Uniform scale factor applied on commit.
    @Binding var scale: CGFloat
    var onDone: () -> Void
    var onCancel: () -> Void
    // Apple-style edit actions.
    var canPaste: Bool = false
    var onCut: () -> Void = {}
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var onDuplicate: () -> Void = {}
    var onDelete: () -> Void = {}

    @State private var rotateStart: Double?
    @State private var dragStart: CGSize?
    @State private var scaleStart: CGFloat?
    @State private var antsPhase: CGFloat = 0

    private let corners: [UnitPoint] = [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing]

    var body: some View {
        let base = transform.toScreen(selection.bounds)
        let size = CGSize(width: base.width * scale, height: base.height * scale)
        let center = CGPoint(x: base.midX + translation.width, y: base.midY + translation.height)

        ZStack {
            // Tap off the selection to commit, like Apple's lasso.
            Color.black.opacity(0.02)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDone)
                .simultaneousGesture(twistGesture)

            Image(uiImage: selection.image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .overlay(
                    Rectangle().strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4], dashPhase: antsPhase))
                )
                .overlay {
                    ForEach(corners, id: \.self) { corner in
                        Circle()
                            .fill(.white)
                            .frame(width: 15, height: 15)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                            .shadow(color: .black.opacity(0.2), radius: 1)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(corner))
                            .contentShape(Rectangle().size(width: 30, height: 30))
                            .gesture(resizeGesture(center: center))
                    }
                }
                .rotationEffect(.degrees(rotation))
                .position(center)
                .gesture(moveGesture)               // one finger drags
                .simultaneousGesture(twistGesture)  // two fingers rotate

            // Apple-style edit menu, floating just above the selection.
            editMenu
                .position(x: center.x, y: max(46, center.y - size.height / 2 - 30))
        }
        .coordinateSpace(name: "strokeTransform")
        .onAppear {
            // Marching ants: the dash sum is 10, so sliding the phase by -10
            // loops seamlessly.
            withAnimation(.linear(duration: 0.5).repeatForever(autoreverses: false)) {
                antsPhase = -10
            }
        }
    }

    // MARK: - Apple-style edit menu

    private var editMenu: some View {
        HStack(spacing: 0) {
            menuButton("Cut", action: onCut)
            menuDivider
            menuButton("Copy", action: onCopy)
            if canPaste {
                menuDivider
                menuButton("Paste", action: onPaste)
            }
            menuDivider
            menuButton("Duplicate", action: onDuplicate)
            menuDivider
            menuButton("Delete", tint: .red, action: onDelete)
        }
        .frame(height: 40)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize()
    }

    private func menuButton(_ title: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var menuDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 0.5, height: 22)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("strokeTransform"))
            .onChanged { value in
                if dragStart == nil { dragStart = translation }
                let b = dragStart ?? .zero
                translation = CGSize(width: b.width + value.translation.width, height: b.height + value.translation.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Uniform resize from a corner: scale by how the drag's distance from the
    /// selection center changes — works under any rotation.
    private func resizeGesture(center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("strokeTransform"))
            .onChanged { value in
                if scaleStart == nil { scaleStart = scale }
                let startDist = hypot(value.startLocation.x - center.x, value.startLocation.y - center.y)
                let nowDist = hypot(value.location.x - center.x, value.location.y - center.y)
                let factor = nowDist / max(startDist, 1)
                scale = min(6, max(0.2, (scaleStart ?? 1) * factor))
            }
            .onEnded { _ in scaleStart = nil }
    }

    private var twistGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(2))
            .onChanged { value in
                if rotateStart == nil { rotateStart = rotation }
                rotation = (rotateStart ?? 0) + value.rotation.degrees
            }
            .onEnded { _ in rotateStart = nil }
    }
}

private extension Alignment {
    init(_ unit: UnitPoint) {
        switch unit {
        case .topLeading: self = .topLeading
        case .topTrailing: self = .topTrailing
        case .bottomLeading: self = .bottomLeading
        case .bottomTrailing: self = .bottomTrailing
        default: self = .center
        }
    }
}
