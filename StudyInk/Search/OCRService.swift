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
                // An unsupported language code can sink the whole request (no
                // results at all, English included) — keep only languages this
                // OS version actually supports, and let Vision auto-detect.
                let supported = (try? request.supportedRecognitionLanguages()) ?? []
                let usable = languages.filter { code in
                    supported.contains { $0 == code || $0.hasPrefix(code + "-") }
                }
                request.recognitionLanguages = usable.isEmpty ? supported : usable
                request.automaticallyDetectsLanguage = true
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
    /// The page render + recognition run off the main thread so writing or typing
    /// (and the keyboard) never stall behind indexing.
    @MainActor
    static func indexPage(_ page: Page) async {
        let snapshot = PageRenderer.Snapshot(page: page)
        let pageSize = snapshot.pageSize
        let lines = await Task.detached(priority: .utility) {
            // Clean, high-res render (white paper, no ruled-line noise) → far better
            // handwriting recognition than the old 1× full-page render.
            let image = PageRenderer.recognitionImage(snapshot, scale: 3)
            return await recognize(image: image, pageSize: pageSize)
        }.value
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
