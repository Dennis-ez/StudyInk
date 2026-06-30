import SwiftUI

// MARK: - Ghost Witness — spatial diagram fitting
//
// The AI reads the student's ROUGH sketch (a Cartesian plane, a lopsided
// parabola, a triangle, matrix brackets…) and returns CLEAN normalized geometry,
// which we paint as faint dashed "ghost" guide lines directly over their ink —
// never touching the actual strokes. A study aid, not an edit.

/// Clean geometry the model fitted to a sketch, in PAGE coordinates.
struct GhostGeometry: Equatable {
    struct Element: Equatable, Identifiable {
        enum Kind: String, Codable { case axis, curve, asymptote, line, point }
        let id = UUID()
        var kind: Kind
        var points: [CGPoint]   // page-space
        var label: String?
    }
    var pageIndex: Int
    var elements: [Element]
}

@MainActor
final class GhostWitnessController: ObservableObject {
    @Published var geometry: GhostGeometry?
    @Published var isFitting = false
    /// Transient banner ("no sketch found" / error).
    @Published var notice: String?
    weak var tutor: AITutorController?

    func dismiss() { withAnimation(.easeOut(duration: 0.25)) { geometry = nil } }

    private func showNotice(_ message: String) {
        notice = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run { if self?.notice == message { self?.notice = nil } }
        }
    }

    /// Fits the current page's sketch and shows the ghost overlay.
    func fit(note: Note, pageIndex: Int, darkMode: Bool) async {
        guard AIConfig.isConfigured else {
            tutor?.errorMessage = AIServiceError.missingKey(AIConfig.provider).localizedDescription
            return
        }
        let pages = note.sortedPages
        guard pages.indices.contains(pageIndex) else { return }
        let page = pages[pageIndex]
        let pageSize = page.canvasSize
        let snapshot = PageRenderer.Snapshot(page: page)

        isFitting = true
        defer { isFitting = false }
        geometry = nil

        let image = await Task.detached(priority: .userInitiated) {
            // Clean render (no ruled/grid lines) so they don't get mistaken for sketch
            // strokes when fitting guide lines. Full page → geometry stays in page coords.
            PageRenderer.recognitionImage(snapshot, scale: 2)
        }.value
        guard let block = AIContent.image(image) else { return }

        do {
            let raw = try await AIService.send(
                system: Self.system,
                messages: [.user([.text(Self.instruction), block])],
                maxTokens: 2500
            )
            let elements = Self.parse(raw, pageSize: pageSize)
            guard !elements.isEmpty else {
                showNotice(String(localized: "ai.ghost.none"))
                return
            }
            withAnimation(.easeOut(duration: 0.35)) {
                geometry = GhostGeometry(pageIndex: pageIndex, elements: elements)
            }
            Haptics.tap()
        } catch {
            Haptics.error()
            tutor?.errorMessage = error.localizedDescription
        }
    }

    // MARK: - AI

    private static let system = """
    You analyze a photo of a student's hand-drawn MATH SKETCH (a function graph, \
    Cartesian axes, a geometric figure, matrix brackets, etc.) and return CLEAN, \
    accurate geometry to overlay as faint guide lines on top of their drawing. \
    Compute the true math where you can (a parabola's vertex and roots, a line's \
    intercepts, an asymptote) rather than just tracing the wobbly ink.
    """

    private static let instruction = """
    Identify the mathematical objects the student SKETCHED and return ONLY a JSON \
    object (you may fence it in a ```json block), no prose:
    {"elements":[{"kind":"axis|curve|asymptote|line|point","points":[[x,y],...],"label":"<optional>"}]}
    - x,y are normalized to THIS image: x 0→1 left→right, y 0→1 top→bottom.
    - "axis": a straight reference axis — exactly 2 points (its endpoints).
    - "curve": the smooth ideal curve they meant (parabola, etc.) — 10–40 ordered points tracing it accurately.
    - "asymptote": a straight reference line they should approach — 2 points.
    - "line": a straight segment — 2 points.
    - "point": ONE marked point (root, vertex, intercept); put its math coordinate in "label" (e.g. "(-2, 0)").
    Only include what the student actually drew or what their visible work clearly implies. \
    If there is no graph/diagram on the page, return {"elements":[]}.
    """

    private static func parse(_ raw: String, pageSize: CGSize) -> [GhostGeometry.Element] {
        guard let slice = jsonSlice(raw)?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: slice) as? [String: Any],
              let arr = obj["elements"] as? [[String: Any]] else { return [] }
        return arr.compactMap { dict -> GhostGeometry.Element? in
            guard let kindStr = dict["kind"] as? String,
                  let kind = GhostGeometry.Element.Kind(rawValue: kindStr),
                  let rawPts = dict["points"] as? [[Any]] else { return nil }
            let pts: [CGPoint] = rawPts.compactMap { pair in
                guard pair.count >= 2,
                      let nx = (pair[0] as? NSNumber)?.doubleValue,
                      let ny = (pair[1] as? NSNumber)?.doubleValue else { return nil }
                return CGPoint(x: CGFloat(nx) * pageSize.width, y: CGFloat(ny) * pageSize.height)
            }
            guard !pts.isEmpty else { return nil }
            let label = (dict["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return GhostGeometry.Element(kind: kind, points: pts, label: label)
        }
    }

    private static func jsonSlice(_ raw: String) -> String? {
        if let f = raw.range(of: "```json", options: .caseInsensitive),
           let c = raw.range(of: "```", range: f.upperBound..<raw.endIndex) {
            return String(raw[f.upperBound..<c.lowerBound])
        }
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s <= e else { return nil }
        return String(raw[s...e])
    }
}

// MARK: - Overlay

/// Paints the fitted geometry as faint dashed guides over the canvas. The guides
/// don't take touches (you can keep drawing under them); only the dismiss chip does.
struct GhostWitnessOverlay: View {
    let geometry: GhostGeometry
    let transform: CanvasTransform
    var onDismiss: () -> Void
    @State private var appeared = false

    private var accent: Color { AppTheme.current.aiAccent }
    private var refColor: Color { SemanticColor.textMutedColor }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ForEach(geometry.elements) { element in
                elementView(element)
            }
            .allowsHitTesting(false)

            Button(action: onDismiss) {
                HStack(spacing: 5) {
                    Lucide("sparkles", size: 12).foregroundStyle(.white)
                    Text("ai.ghost.dismiss").font(.caption.weight(.semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(accent, in: Capsule())
                .shadow(color: accent.opacity(0.4), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.top, 92)
            .padding(.trailing, 22)
        }
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.4)) { appeared = true } }
    }

    @ViewBuilder
    private func elementView(_ element: GhostGeometry.Element) -> some View {
        let pts = element.points.map(transform.toScreen)
        switch element.kind {
        case .point:
            if let p = pts.first {
                ZStack {
                    Circle().stroke(accent, lineWidth: 2).frame(width: 11, height: 11)
                    Circle().fill(accent.opacity(0.5)).frame(width: 5, height: 5)
                    if let label = element.label {
                        Text(label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            .offset(y: -16)
                            .fixedSize()
                    }
                }
                .position(p)
            }
        default:
            ghostPath(pts)
                .stroke(strokeColor(element.kind),
                        style: StrokeStyle(lineWidth: element.kind == .curve ? 2.2 : 1.5,
                                           lineCap: .round, lineJoin: .round,
                                           dash: element.kind == .axis ? [] : [7, 5]))
                .opacity(element.kind == .axis ? 0.55 : 0.85)
        }
    }

    /// Smooth path for curves (Catmull-Rom), straight for everything else.
    private func ghostPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else { for p in pts.dropFirst() { path.addLine(to: p) }; return path }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private func strokeColor(_ kind: GhostGeometry.Element.Kind) -> Color {
        switch kind {
        case .axis: return refColor
        case .asymptote: return refColor
        case .curve, .line, .point: return accent
        }
    }
}
