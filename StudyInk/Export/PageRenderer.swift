import UIKit
import PencilKit
import PDFKit

/// Composites a full page — background, template/PDF, media, ink, typed text —
/// into a UIImage or PDF. Used by export, share, and the AI context builder.
enum PageRenderer {
    /// Canvas/background colors mirror the asset catalog tokens; resolved here
    /// explicitly so rendering can target either appearance regardless of UI state.
    static func backgroundColor(darkMode: Bool) -> UIColor {
        darkMode ? UIColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1) : .white
    }

    static func image(for page: Page, darkMode: Bool, scale: CGFloat = 1) -> UIImage {
        let pageSize = PageSize.from(id: page.pageSizeID).size
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: pageSize, format: format)
        return renderer.image { ctx in
            draw(page: page, in: ctx.cgContext, pageSize: pageSize, darkMode: darkMode)
        }
    }

    static func pdfData(for note: Note, darkMode: Bool = false) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: .zero)
        return renderer.pdfData { ctx in
            for page in note.sortedPages {
                let pageSize = PageSize.from(id: page.pageSizeID).size
                ctx.beginPage(withBounds: CGRect(origin: .zero, size: pageSize), pageInfo: [:])
                draw(page: page, in: ctx.cgContext, pageSize: pageSize, darkMode: darkMode)
            }
        }
    }

    static func pngData(for page: Page, darkMode: Bool) -> Data? {
        image(for: page, darkMode: darkMode, scale: 2).pngData()
    }

    private static func draw(page: Page, in cg: CGContext, pageSize: CGSize, darkMode: Bool) {
        let pageRect = CGRect(origin: .zero, size: pageSize)

        cg.setFillColor(backgroundColor(darkMode: darkMode).cgColor)
        cg.fill(pageRect)

        // Template or custom PDF background.
        if page.template == .customPDF, let data = page.customTemplatePDF,
           let pdfImage = PDFTemplateRenderer.image(from: data, targetWidth: pageSize.width * 2) {
            pdfImage.draw(in: pageRect, blendMode: .normal, alpha: darkMode ? 0.85 : 1)
        } else {
            let lineColor = darkMode
                ? UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1)
                : UIColor(red: 0.82, green: 0.82, blue: 0.839, alpha: 1)
            let accent = darkMode
                ? UIColor(red: 0.039, green: 0.518, blue: 1, alpha: 1)
                : UIColor(red: 0, green: 0.478, blue: 1, alpha: 1)
            page.template.drawCG(in: cg, rect: pageRect, scale: 1, lineColor: lineColor.cgColor, accentColor: accent.cgColor)
        }

        // Media below ink, matching the editor's layer order.
        for item in page.mediaItems {
            MediaStore.image(named: item.fileName)?.draw(in: item.frame)
        }

        // Ink, appearance-resolved so dark-remapped colors render correctly.
        let drawing = page.drawing
        if !drawing.strokes.isEmpty {
            let traits = UITraitCollection(userInterfaceStyle: darkMode ? .dark : .light)
            var inkImage: UIImage?
            traits.performAsCurrent {
                inkImage = drawing.image(from: pageRect, scale: 2)
            }
            inkImage?.draw(in: pageRect)
        }

        // Typed text boxes.
        for box in page.textBoxes {
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
}
