import SwiftUI
import PDFKit

/// Built-in page background templates. The drawing core targets CGContext so the
/// same code paints the live canvas (via GraphicsContext), thumbnails, PDF/PNG
/// export, and AI context renders — always with semantic, dark-mode-aware colors.
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

    /// SwiftUI entry point — bridges into the CGContext core.
    func draw(in ctx: inout GraphicsContext, rect: CGRect, scale: CGFloat, lineColor: Color, accentColor: Color, spacing: CGFloat = 1) {
        let line = UIColor(lineColor).cgColor
        let accent = UIColor(accentColor).cgColor
        ctx.withCGContext { cg in
            drawCG(in: cg, rect: rect, scale: scale, lineColor: line, accentColor: accent, spacing: spacing)
        }
    }

    /// Core renderer. `rect` is the page rect in the destination space; `scale`
    /// converts page points to that space; `spacing` scales line/grid density.
    func drawCG(in cg: CGContext, rect: CGRect, scale rawScale: CGFloat, lineColor: CGColor, accentColor: CGColor, spacing: CGFloat = 1) {
        let scale = rawScale * max(spacing, 0.4)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.clip(to: rect)
        cg.setLineWidth(max(0.5, 0.7 * scale.squareRoot()))

        switch self {
        case .blank, .customPDF:
            return
        case .wideRuled:
            rules(cg, rect: rect, spacing: 34 * scale, color: lineColor)
        case .collegeRuled:
            rules(cg, rect: rect, spacing: 26 * scale, color: lineColor)
            vertical(cg, rect: rect, x: rect.minX + 64 * scale, color: accentColor)
        case .narrowRuled:
            rules(cg, rect: rect, spacing: 20 * scale, color: lineColor)
        case .dotGrid:
            let step = 24 * scale
            cg.setFillColor(lineColor)
            var y = rect.minY + step
            while y < rect.maxY {
                var x = rect.minX + step
                while x < rect.maxX {
                    cg.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    x += step
                }
                y += step
            }
        case .squareGrid:
            let step = 24 * scale
            cg.setStrokeColor(lineColor)
            var x = rect.minX
            while x <= rect.maxX {
                line(cg, from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY))
                x += step
            }
            var y = rect.minY
            while y <= rect.maxY {
                line(cg, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y))
                y += step
            }
        case .isometricGrid:
            let step = 28 * scale
            let rise = rect.width * 0.577  // tan(30°)
            cg.setStrokeColor(lineColor)
            var c = rect.minY - rise
            while c < rect.maxY + rise {
                line(cg, from: CGPoint(x: rect.minX, y: c), to: CGPoint(x: rect.maxX, y: c + rise))
                line(cg, from: CGPoint(x: rect.minX, y: c + rise), to: CGPoint(x: rect.maxX, y: c))
                c += step
            }
        case .musicStaff:
            let lineGap = 10 * scale
            let blockGap = 70 * scale
            cg.setStrokeColor(lineColor)
            var y = rect.minY + 60 * scale
            while y + 4 * lineGap < rect.maxY - 30 * scale {
                for i in 0..<5 {
                    let lineY = y + CGFloat(i) * lineGap
                    line(cg, from: CGPoint(x: rect.minX + 30 * scale, y: lineY),
                         to: CGPoint(x: rect.maxX - 30 * scale, y: lineY))
                }
                y += blockGap
            }
        case .cornell:
            let cueX = rect.minX + rect.width * 0.28
            let headerY = rect.minY + 50 * scale
            let summaryY = rect.maxY - rect.height * 0.18
            rules(cg, rect: CGRect(x: rect.minX, y: headerY, width: rect.width, height: summaryY - headerY), spacing: 26 * scale, color: lineColor)
            vertical(cg, rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: summaryY - rect.minY), x: cueX, color: accentColor)
            cg.setStrokeColor(accentColor)
            cg.setLineWidth(1.5)
            line(cg, from: CGPoint(x: rect.minX, y: headerY), to: CGPoint(x: rect.maxX, y: headerY))
            line(cg, from: CGPoint(x: rect.minX, y: summaryY), to: CGPoint(x: rect.maxX, y: summaryY))
        }
    }

    private func rules(_ cg: CGContext, rect: CGRect, spacing: CGFloat, color: CGColor) {
        guard spacing > 1 else { return }
        cg.setStrokeColor(color)
        var y = rect.minY + spacing
        while y < rect.maxY {
            line(cg, from: CGPoint(x: rect.minX, y: y), to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
    }

    private func vertical(_ cg: CGContext, rect: CGRect, x: CGFloat, color: CGColor) {
        cg.setStrokeColor(color.copy(alpha: 0.6) ?? color)
        line(cg, from: CGPoint(x: x, y: rect.minY), to: CGPoint(x: x, y: rect.maxY))
    }

    private func line(_ cg: CGContext, from: CGPoint, to: CGPoint) {
        cg.move(to: from)
        cg.addLine(to: to)
        cg.strokePath()
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
        Canvas { ctx, size in
            let pageRect = transform.toScreen(CGRect(origin: .zero, size: pageSize))

            // Desk surface behind the page, so the page reads as a sheet of
            // paper with a soft shadow in both light and dark mode.
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color("deskBackground")))
            var shadowCtx = ctx
            shadowCtx.addFilter(.shadow(color: .black.opacity(0.28), radius: 14, y: 5))
            shadowCtx.fill(Path(roundedRect: pageRect, cornerRadius: 2), with: .color(Color("canvasBackground")))
            ctx.stroke(Path(roundedRect: pageRect, cornerRadius: 2), with: .color(Color("aiBubbleBorder").opacity(0.5)), lineWidth: 0.5)

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
        guard template == .customPDF, let data = customPDFData else {
            pdfImage = nil
            return
        }
        pdfImage = PDFTemplateRenderer.image(from: data, targetWidth: pageSize.width * 2)
    }
}

enum PDFTemplateRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func image(from data: Data, targetWidth: CGFloat, darkMode: Bool = false) -> UIImage? {
        guard let doc = PDFDocument(data: data), let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let scale = max(targetWidth / max(bounds.width, 1), 1)
        let rendered = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return darkMode ? darkOptimized(rendered) : rendered
    }

    /// "Smart invert" for documents: invert luminance, then rotate hue 180° so
    /// colors keep their identity — white paper becomes dark, black text light.
    private static func darkOptimized(_ image: UIImage) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let inverted = input.applyingFilter("CIColorInvert")
        let hueFixed = inverted.applyingFilter("CIHueAdjust", parameters: ["inputAngle": CGFloat.pi])
        guard let cg = ciContext.createCGImage(hueFixed, from: hueFixed.extent) else { return image }
        return UIImage(cgImage: cg)
    }
}
