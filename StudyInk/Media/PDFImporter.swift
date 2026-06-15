import PDFKit
import UIKit

/// PDF intake: either inline (each PDF page becomes a note page you annotate on top of)
/// or as a reusable background template for the current page.
enum PDFImporter {
    /// Appends every page of the PDF as new note pages with the PDF page as background.
    static func importAsPages(data: Data, into note: Note, after pageIndex: Int32) {
        guard let document = PDFDocument(data: data) else { return }
        // Match the note's existing page width so imported PDF pages line up
        // with the handwritten ones; height follows each PDF page's aspect.
        let referenceWidth = note.sortedPages.first?.canvasSize.width ?? PageSize.letter.size.width
        var insertAfter = pageIndex
        for i in 0..<document.pageCount {
            guard let pdfPage = document.page(at: i),
                  let singlePageData = singlePageData(from: pdfPage) else { continue }
            let page = note.addPage(after: insertAfter, templateID: PageTemplate.customPDF.rawValue)
            page.customTemplatePDF = singlePageData
            let raw = pdfPage.bounds(for: .mediaBox)
            // bounds(for:) ignores page rotation — swap for 90°/270° pages.
            let rotated = abs(pdfPage.rotation) % 180 == 90
            let w = rotated ? raw.height : raw.width
            let h = rotated ? raw.width : raw.height
            let aspect = w > 0 ? h / w : (PageSize.letter.size.height / PageSize.letter.size.width)
            page.pageWidth = referenceWidth
            page.pageHeight = referenceWidth * aspect
            insertAfter += 1
        }
    }

    /// Sets the PDF's first page as the background template of an existing page.
    static func importAsTemplate(data: Data, for page: Page) {
        guard let document = PDFDocument(data: data), let first = document.page(at: 0),
              let singlePage = singlePageData(from: first) else { return }
        page.templateID = PageTemplate.customPDF.rawValue
        page.customTemplatePDF = singlePage
        page.note?.touch()
    }

    private static func singlePageData(from page: PDFPage) -> Data? {
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc.dataRepresentation()
    }
}
