import Vision
import UIKit

/// One recognized line of handwriting/typed text with its location on the page,
/// in page coordinates. Boxes feed both search indexing and AI annotation targeting.
struct OCRLine: Equatable {
    let text: String
    let rect: CGRect
    let confidence: Float
}

/// Handwriting + print recognition via Vision, Hebrew and English (covers Latin
/// math notation as recognized text). All work happens off the main thread.
enum OCRService {
    static let languages = ["he", "en"]

    /// Recognizes text in a rendered page image. `pageSize` converts Vision's
    /// normalized, bottom-left-origin boxes into top-left page coordinates.
    static func recognize(image: UIImage, pageSize: CGSize) async -> [OCRLine] {
        guard let cgImage = image.cgImage else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, _ in
                    let lines: [OCRLine] = (request.results as? [VNRecognizedTextObservation])?.compactMap { obs in
                        guard let candidate = obs.topCandidates(1).first else { return nil }
                        let b = obs.boundingBox
                        let rect = CGRect(
                            x: b.minX * pageSize.width,
                            y: (1 - b.maxY) * pageSize.height,
                            width: b.width * pageSize.width,
                            height: b.height * pageSize.height
                        )
                        return OCRLine(text: candidate.string, rect: rect, confidence: candidate.confidence)
                    } ?? []
                    continuation.resume(returning: lines)
                }
                request.recognitionLevel = .accurate
                request.recognitionLanguages = languages
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    /// Recognizes a page's current contents and caches the text for library search.
    @MainActor
    static func indexPage(_ page: Page) async {
        let pageSize = PageSize.from(id: page.pageSizeID).size
        let image = PageRenderer.image(for: page, darkMode: false)
        let lines = await recognize(image: image, pageSize: pageSize)
        let text = lines.map(\.text).joined(separator: "\n")
        if page.ocrText != text {
            page.ocrText = text
            if let note = page.note {
                note.searchableText = SearchableTextBuilder.build(for: note)
            }
            PersistenceController.shared.save()
        }
    }
}
