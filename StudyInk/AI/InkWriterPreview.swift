import SwiftUI
import PencilKit

/// DEV-only harness to eyeball AI handwriting (InkWriter) without an API key.
/// Shown instead of the library when the app is launched with the env var
/// INK_PREVIEW=1 (see ContentView). Renders sample strings through the same path
/// the AI ink uses, so a screenshot reveals the real glyph quality.
struct InkWriterPreview: View {
    private let samples: [(String, CGFloat)] = [
        ("f(x) = 2x + 3", 34),
        ("The derivative is correct", 26),
        ("\\frac{x+1}{x-1} = 0", 34),
        ("a^2 + b^2 = c^2", 30),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("AI handwriting — constant width vs. natural taper")
                    .font(.headline).padding(.bottom, 4)
                ForEach(samples.indices, id: \.self) { i in
                    let (text, size) = samples[i]
                    HStack(alignment: .top, spacing: 24) {
                        cell("before", Self.render(text, fontSize: size, taper: false))
                        cell("after (taper)", Self.render(text, fontSize: size, taper: true))
                    }
                }
            }
            .padding(28)
        }
        .background(Color.white)
    }

    private func cell(_ label: String, _ img: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let img { Image(uiImage: img).border(Color.gray.opacity(0.25)) }
        }
    }

    /// Render one sample the way AI ink reaches the canvas: InkWriter → vector → image.
    static func render(_ text: String, fontSize: CGFloat, taper: Bool) -> UIImage? {
        let ink = PKInk(.pen, color: UIColor(red: 0.04, green: 0.2, blue: 0.45, alpha: 1))
        let pk = InkWriter.strokes(for: text, topLeft: CGPoint(x: 8, y: 8),
                                   fontSize: fontSize, ink: ink,
                                   strokeWidth: max(2.4, fontSize * 0.135))
        guard !pk.isEmpty else { return nil }
        var vec = VectorInk.strokes(from: PKDrawing(strokes: pk))
        if taper { vec = VectorInk.tapered(vec) }
        guard !vec.isEmpty else { return nil }
        let bounds = vec.dropFirst().reduce(vec[0].bbox) { $0.union($1.bbox) }
        let size = CGSize(width: bounds.maxX + 16, height: bounds.maxY + 16)
        return VectorInk.image(vec, size: size, scale: 2)
    }
}
