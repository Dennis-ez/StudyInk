import SwiftUI
import PDFKit

/// Built-in page background templates. Drawn vector-style in page space so they
/// stay crisp at any zoom, using the semantic templateLine color (dark-mode aware).
enum PageTemplate: String, CaseIterable, Codable, Identifiable {
    case blank
    case wideRuled, collegeRuled, narrowRuled
    case dotGrid, squareGrid, isometricGrid
    case musicStaff
    case cornell
    case customPDF

    var id: String { rawValue }

    var labelKey: LocalizedStringKey {
        switch self {
        case .blank: return "template.blank"
        case .wideRuled: return "template.wideRuled"
        case .collegeRuled: return "template.collegeRuled"
        case .narrowRuled: return "template.narrowRuled"
        case .dotGrid: return "template.dotGrid"
        case .squareGrid: return "template.squareGrid"
        case .isometricGrid: return "template.isometricGrid"
        case .musicStaff: return "template.musicStaff"
        case .cornell: return "template.cornell"
        case .customPDF: return "template.customPDF"
        }
    }

    var symbolName: String {
        switch self {
        case .blank: return "doc"
        case .wideRuled, .collegeRuled, .narrowRuled: return "doc.text"
        case .dotGrid: return "circle.grid.3x3"
        case .squareGrid: return "squareshape.split.3x3"
        case .isometricGrid: return "triangle"
        case .musicStaff: return "music.note"
        case .cornell: return "rectangle.split.3x1"
        case .customPDF: return "doc.richtext"
        }
    }

    static func from(id: String?) -> PageTemplate {
        PageTemplate(rawValue: id ?? "blank") ?? .blank
    }

    /// Draws the template into a SwiftUI GraphicsContext. `rect` is the page rect in
    /// the destination coordinate space; `scale` converts page points to that space.
    func draw(in ctx: inout GraphicsContext, rect: CGRect, scale: CGFloat, lineColor: Color, accentColor: Color) {
        switch self {
        case .blank, .customPDF:
            return
        case .wideRuled:
            drawRules(in: &ctx, rect: rect, spacing: 34 * scale, color: lineColor)
        case .collegeRuled:
            drawRules(in: &ctx, rect: rect, spacing: 26 * scale, color: lineColor)
            drawMargin(in: &ctx, rect: rect, x: rect.minX + 64 * scale, color: accentColor)
        case .narrowRuled:
            drawRules(in: &ctx, rect: rect, spacing: 20 * scale, color: lineColor)
        case .dotGrid:
            let step = 24 * scale
            var y = rect.minY + step
            while y < rect.maxY {
                var x = rect.minX + step
                while x < rect.maxX {
                    let dot = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    ctx.fill(Path(ellipseIn: dot), with: .color(lineColor))
                    x += step
                }
                y += step
            }
        case .squareGrid:
            let step = 24 * scale
            var x = rect.minX
            while x <= rect.maxX {
                stroke(&ctx, from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY), color: lineColor)
                x += step
            }
            var y = rect.minY
            while y <= rect.maxY {
                stroke(&ctx, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y), color: lineColor)
                y += step
            }
        case .isometricGrid:
            let step = 28 * scale
            let slope: CGFloat = 0.577  // tan(30°)
            var c = rect.minY - rect.width * slope
            while c < rect.maxY + rect.width * slope {
                stroke(&ctx, from: CGPoint(x: rect.minX, y: c), to: CGPoint(x: rect.maxX, y: c + rect.width * slope), color: lineColor)
                stroke(&ctx, from: CGPoint(x: rect.minX, y: c + rect.width * slope), to: CGPoint(x: rect.maxX, y: c), color: lineColor)
                c += step
            }
        case .musicStaff:
            let staffLineGap = 10 * scale
            let staffBlockGap = 70 * scale
            var y = rect.minY + 60 * scale
            while y + 4 * staffLineGap < rect.maxY - 30 * scale {
                for line in 0..<5 {
                    let lineY = y + CGFloat(line) * staffLineGap
                    stroke(&ctx, from: CGPoint(x: rect.minX + 30 * scale, y: lineY),
                           to: CGPoint(x: rect.maxX - 30 * scale, y: lineY), color: lineColor)
                }
                y += staffBlockGap
            }
        case .cornell:
            // Cue column, note area, summary strip.
            let cueX = rect.minX + rect.width * 0.28
            let summaryY = rect.maxY - rect.height * 0.18
            drawRules(in: &ctx, rect: CGRect(x: rect.minX, y: rect.minY + 50 * scale, width: rect.width, height: summaryY - rect.minY - 50 * scale), spacing: 26 * scale, color: lineColor)
            drawMargin(in: &ctx, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: summaryY - rect.minY), x: cueX, color: accentColor)
            stroke(&ctx, from: CGPoint(x: rect.minX, y: summaryY), to: CGPoint(x: rect.maxX, y: summaryY), color: accentColor, lineWidth: 1.5)
            stroke(&ctx, from: CGPoint(x: rect.minX, y: rect.minY + 50 * scale), to: CGPoint(x: rect.maxX, y: rect.minY + 50 * scale), color: accentColor, lineWidth: 1.5)
        }
    }

    private func drawRules(in ctx: inout GraphicsContext, rect: CGRect, spacing: CGFloat, color: Color) {
        guard spacing > 1 else { return }
        var y = rect.minY + spacing
        while y < rect.maxY {
            stroke(&ctx, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y), color: color)
            y += spacing
        }
    }

    private func drawMargin(in ctx: inout GraphicsContext, rect: CGRect, x: CGFloat, color: Color) {
        stroke(&ctx, from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY), color: color.opacity(0.6), lineWidth: 1.2)
    }

    private func stroke(_ ctx: inout GraphicsContext, from: CGPoint, to: CGPoint, color: Color, lineWidth: CGFloat = 0.7) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
    }
}

/// Renders the page background (color + template pattern or custom PDF) behind the ink,
/// tracking canvas zoom/scroll so the pattern stays glued to the page.
struct TemplateBackgroundView: View {
    let template: PageTemplate
    let pageSize: CGSize
    let transform: CanvasTransform
    let customPDFData: Data?

    @State private var pdfImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { ctx, _ in
            let pageRect = transform.toScreen(CGRect(origin: .zero, size: pageSize))
            ctx.fill(Path(pageRect), with: .color(Color("canvasBackground")))

            if template == .customPDF, let pdfImage {
                // PDF templates keep their own colors; dim slightly in dark mode for comfort.
                var imageCtx = ctx
                if colorScheme == .dark { imageCtx.opacity = 0.85 }
                imageCtx.draw(Image(uiImage: pdfImage), in: pageRect)
            } else {
                template.draw(
                    in: &ctx,
                    rect: pageRect,
                    scale: transform.zoomScale,
                    lineColor: Color("templateLine"),
                    accentColor: Color("accentBlue")
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: customPDFData) { renderPDF() }
    }

    private func renderPDF() {
        guard template == .customPDF, let data = customPDFData,
              let doc = PDFDocument(data: data), let page = doc.page(at: 0) else {
            pdfImage = nil
            return
        }
        let bounds = page.bounds(for: .mediaBox)
        let renderScale = max(pageSize.width / max(bounds.width, 1), 1) * 2
        pdfImage = page.thumbnail(of: CGSize(width: bounds.width * renderScale, height: bounds.height * renderScale), for: .mediaBox)
    }
}
