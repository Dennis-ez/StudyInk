import SwiftUI
import PencilKit
import CoreData

/// DEV-only harness to eyeball AI handwriting (InkWriter) + the OCR / AI-vision render
/// without an API key. Shown instead of the library when the app is launched with the
/// env var INK_PREVIEW=1 (see ContentView).
struct InkWriterPreview: View {
    private let samples: [(String, CGFloat)] = [
        ("f(x) = 2x + 3", 34),
        ("The derivative is correct", 26),
        ("\\frac{x+1}{x-1} = 0", 34),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("AI handwriting — constant width vs. natural taper")
                    .font(.headline)
                ForEach(samples.indices, id: \.self) { i in
                    let (text, size) = samples[i]
                    HStack(alignment: .top, spacing: 24) {
                        cell("before", Self.renderInk(text, fontSize: size, taper: false))
                        cell("after (taper)", Self.renderInk(text, fontSize: size, taper: true))
                    }
                }

                Divider().padding(.vertical, 8)
                Text("Page render for OCR / AI vision — full page vs. clean recognition")
                    .font(.headline)
                if let snap = Self.firstPageSnapshot() {
                    HStack(alignment: .top, spacing: 24) {
                        cell("old: full page @1×", PageRenderer.render(snap, darkMode: false, scale: 1)
                            .resized(toWidth: 300))
                        cell("new: recognition @3×", PageRenderer.recognitionImage(snap, scale: 3)
                            .resized(toWidth: 300))
                    }
                } else {
                    Text("(no note found to render)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
        .background(Color.white)
    }

    private func cell(_ label: String, _ img: UIImage?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            if let img { Image(uiImage: img).border(Color.gray.opacity(0.3)) }
        }
    }

    static func renderInk(_ text: String, fontSize: CGFloat, taper: Bool) -> UIImage? {
        let ink = PKInk(.pen, color: UIColor(red: 0.04, green: 0.2, blue: 0.45, alpha: 1))
        let pk = InkWriter.strokes(for: text, topLeft: CGPoint(x: 8, y: 8),
                                   fontSize: fontSize, ink: ink, strokeWidth: max(2.4, fontSize * 0.135))
        guard !pk.isEmpty else { return nil }
        var vec = VectorInk.strokes(from: PKDrawing(strokes: pk))
        if taper { vec = VectorInk.tapered(vec) }
        guard !vec.isEmpty else { return nil }
        let b = vec.dropFirst().reduce(vec[0].bbox) { $0.union($1.bbox) }
        return VectorInk.image(vec, size: CGSize(width: b.maxX + 16, height: b.maxY + 16), scale: 2)
    }

    @MainActor static func firstPageSnapshot() -> PageRenderer.Snapshot? {
        let ctx = PersistenceController.shared.viewContext
        let req = NSFetchRequest<Note>(entityName: "Note")
        req.fetchLimit = 1
        guard let note = (try? ctx.fetch(req))?.first, let page = note.sortedPages.first else { return nil }
        return PageRenderer.Snapshot(page: page)
    }
}

private extension UIImage {
    func resized(toWidth w: CGFloat) -> UIImage {
        let h = size.height * (w / max(size.width, 1))
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { _ in
            draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
}
