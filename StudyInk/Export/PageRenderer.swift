import UIKit
import PencilKit
import PDFKit

/// Composites a full page — background, template/PDF, media, ink, typed text —
/// into a UIImage or PDF. Used by export, share, OCR, and the AI context builder.
///
/// Rendering can take hundreds of milliseconds per page, so the heavy path is
/// split in two: a cheap main-actor `Snapshot` copies the page's value data out
/// of Core Data, and `render(_:)` does the actual drawing on any thread.
enum PageRenderer {
    /// Value-type copy of everything needed to draw a page, safe to ship to a
    /// background thread (Core Data objects are main-actor only).
    struct Snapshot {
        let pageSize: CGSize
        let template: PageTemplate
        let templateSpacing: CGFloat
        let customTemplatePDF: Data?
        let drawingData: Data?
        let mediaItems: [MediaItemModel]
        let textBoxes: [TextBoxModel]

        @MainActor
        init(page: Page) {
            pageSize = page.canvasSize
            template = page.template
            templateSpacing = page.effectiveTemplateSpacing
            customTemplatePDF = page.customTemplatePDF
            drawingData = page.drawingData
            mediaItems = page.mediaItems
            textBoxes = page.textBoxes
        }
    }

    /// Canvas/background colors mirror the asset catalog tokens; resolved here
    /// explicitly so rendering can target either appearance regardless of UI state.
    static func backgroundColor(darkMode: Bool) -> UIColor {
        darkMode ? UIColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1) : .white
    }

    /// Thread-safe core renderer — call from a background task for heavy work.
    static func render(_ snapshot: Snapshot, darkMode: Bool, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: snapshot.pageSize, format: format)
        // In a tiny preview the page is shrunk many times, so a normal 2–3pt
        // stroke falls below a pixel and antialiases to near-invisible grey —
        // sparse handwriting then "vanishes". Fatten the ink the more we shrink
        // so it still reads, tapering back to 1× at full size.
        let inkBoost = min(4, max(1, 0.5 / scale))
        return renderer.image { ctx in
            draw(snapshot, in: ctx.cgContext, darkMode: darkMode, inkBoost: inkBoost)
        }
    }

    @MainActor
    static func image(for page: Page, darkMode: Bool, scale: CGFloat = 1) -> UIImage {
        render(Snapshot(page: page), darkMode: darkMode, scale: scale)
    }

    @MainActor
    static func pdfData(for note: Note, darkMode: Bool = false) -> Data {
        let all = note.sortedPages.map(Snapshot.init)
        // Auto-appended trailing pages (and any other untouched page) stay out
        // of the export; an entirely empty note still exports its first page.
        let nonEmpty = all.filter(hasContent)
        let snapshots = nonEmpty.isEmpty ? Array(all.prefix(1)) : nonEmpty
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        return renderer.pdfData { ctx in
            for snapshot in snapshots {
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: snapshot.pageSize), pageInfo: [:])
                draw(snapshot, in: ctx.cgContext, darkMode: darkMode)
            }
        }
    }

    @MainActor
    static func pngData(for page: Page, darkMode: Bool) -> Data? {
        image(for: page, darkMode: darkMode, scale: 2).pngData()
    }

    /// A page is worth exporting if it has ink, media, typed text, or an
    /// imported PDF behind it.
    static func hasContent(_ snapshot: Snapshot) -> Bool {
        if snapshot.customTemplatePDF != nil { return true }
        if !snapshot.mediaItems.isEmpty { return true }
        if snapshot.textBoxes.contains(where: { !$0.text.isEmpty }) { return true }
        if let data = snapshot.drawingData,
           let drawing = try? PKDrawing(data: data),
           !drawing.strokes.isEmpty { return true }
        return false
    }

    /// Paper + template/PDF only — shared by full renders and the live page
    /// container (which layers the live canvas and SwiftUI overlays on top).
    static func drawBackground(_ snapshot: Snapshot, in cg: CGContext, darkMode: Bool) {
        let pageRect = CGRect(origin: .zero, size: snapshot.pageSize)

        cg.setFillColor(backgroundColor(darkMode: darkMode).cgColor)
        cg.fill(pageRect)

        // Rasterize the PDF at the destination's actual pixel scale (capped to
        // bound memory) so it stays sharp at retina + zoom, not a soft 2x.
        let pixelScale = min(max(abs(cg.ctm.a), 2), 3)
        if snapshot.template == .customPDF, let data = snapshot.customTemplatePDF,
           let pdfImage = PDFTemplateRenderer.image(from: data, targetWidth: snapshot.pageSize.width * pixelScale, darkMode: darkMode) {
            // Aspect-fit: a PDF must never run wider (or taller) than the page.
            let imageSize = pdfImage.size
            let fit = min(pageRect.width / max(imageSize.width, 1), pageRect.height / max(imageSize.height, 1))
            let drawSize = CGSize(width: imageSize.width * fit, height: imageSize.height * fit)
            pdfImage.draw(in: CGRect(
                x: pageRect.midX - drawSize.width / 2,
                y: pageRect.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            ))
        } else {
            let lineColor = darkMode
                ? UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1)
                : UIColor(red: 0.82, green: 0.82, blue: 0.839, alpha: 1)
            let accent = darkMode
                ? UIColor(red: 0.039, green: 0.518, blue: 1, alpha: 1)
                : UIColor(red: 0, green: 0.478, blue: 1, alpha: 1)
            snapshot.template.drawCG(in: cg, rect: pageRect, scale: 1, lineColor: lineColor.cgColor, accentColor: accent.cgColor, spacing: snapshot.templateSpacing)
        }
    }

    private static func draw(_ snapshot: Snapshot, in cg: CGContext, darkMode: Bool, inkBoost: CGFloat = 1) {
        let pageRect = CGRect(origin: .zero, size: snapshot.pageSize)

        drawBackground(snapshot, in: cg, darkMode: darkMode)

        // Media below ink, matching the editor's layer order.
        for item in snapshot.mediaItems {
            MediaStore.image(named: item.fileName)?.draw(in: item.frame)
        }

        // Ink. We pre-map storage → display ourselves (black ink → near-white
        // on a dark page). PKDrawing.image() then still re-adapts colors
        // against the ambient appearance on iOS 26, so render it in a fixed
        // LIGHT trait context — exactly like the live canvas, which is pinned
        // to .light — so the near-white strokes render literally.
        if let data = snapshot.drawingData, let stored = try? PKDrawing(data: data), !stored.strokes.isEmpty {
            let adapted = InkColorAdapter.displayDrawing(stored, darkMode: darkMode)
            let drawing = boldened(adapted, factor: inkBoost)
            var inkImage: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                inkImage = drawing.image(from: pageRect, scale: 2)
            }
            inkImage?.draw(in: pageRect)
        }

        // Typed text boxes.
        for box in snapshot.textBoxes {
            let paragraph = NSMutableParagraphStyle()
            paragraph.baseWritingDirection = box.isRTL ? .rightToLeft : .leftToRight
            switch box.textAlignment {
            case .center: paragraph.alignment = .center
            case .trailing: paragraph.alignment = .right
            default: paragraph.alignment = box.isRTL ? .right : .left
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: box.uiFont,
                .foregroundColor: UIColor(hex: box.colorHex) ?? .label,
                .paragraphStyle: paragraph,
            ]
            if box.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if box.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            NSAttributedString(string: box.text, attributes: attributes)
                .draw(in: box.frame.insetBy(dx: 4, dy: 4))
        }
    }

    /// Widens every stroke by `factor` (preserving relative widths) so ink stays
    /// legible in heavily-shrunk previews. `factor == 1` returns the drawing as-is.
    private static func boldened(_ drawing: PKDrawing, factor: CGFloat) -> PKDrawing {
        guard factor > 1.001 else { return drawing }
        var strokes = drawing.strokes
        for i in strokes.indices {
            let s = strokes[i]
            let path = s.path
            let points = (0..<path.count).map { index -> PKStrokePoint in
                let p = path[index]
                return PKStrokePoint(
                    location: p.location, timeOffset: p.timeOffset,
                    size: CGSize(width: p.size.width * factor, height: p.size.height * factor),
                    opacity: p.opacity, force: p.force, azimuth: p.azimuth, altitude: p.altitude
                )
            }
            strokes[i] = PKStroke(
                ink: s.ink,
                path: PKStrokePath(controlPoints: points, creationDate: path.creationDate),
                transform: s.transform, mask: s.mask
            )
        }
        return PKDrawing(strokes: strokes)
    }
}
