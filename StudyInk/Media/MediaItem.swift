import SwiftUI

/// A media object placed on a page (image, sticker, or inline PDF page).
/// Pixel data lives in MediaStore files; the model only keeps a reference.
struct MediaItemModel: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case image, sticker, pdfPage }

    var id = UUID()
    var kind: Kind = .image
    var fileName: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double = 0

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.origin.x; y = newValue.origin.y; width = newValue.width; height = newValue.height }
    }
}

/// Flat file store for media payloads under Application Support/Media.
enum MediaStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var stickerDirectory: URL {
        let dir = directory.appendingPathComponent("Stickers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    static func save(_ data: Data, fileExtension: String = "png", sticker: Bool = false) -> String? {
        let name = UUID().uuidString + "." + fileExtension
        let url = (sticker ? stickerDirectory : directory).appendingPathComponent(name)
        do {
            try data.write(to: url)
            return name
        } catch {
            return nil
        }
    }

    static func image(named fileName: String) -> UIImage? {
        if let img = UIImage(contentsOfFile: directory.appendingPathComponent(fileName).path) { return img }
        return UIImage(contentsOfFile: stickerDirectory.appendingPathComponent(fileName).path)
    }

    static func userStickers() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: stickerDirectory.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".png") }.sorted()
    }

    static func delete(fileName: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
    }

    /// Copies a payload to a fresh filename (so a duplicate doesn't share — and
    /// can't be orphaned by deleting — the original's file). Returns the new name.
    static func duplicate(fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.isEmpty ? "png" : (fileName as NSString).pathExtension
        if let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) {
            return save(data, fileExtension: ext)
        }
        if let data = try? Data(contentsOf: stickerDirectory.appendingPathComponent(fileName)) {
            return save(data, fileExtension: ext, sticker: true)
        }
        return nil
    }
}

/// Pre-made sticker library: bundled glyph stickers rendered on demand, plus user PNGs.
enum StickerLibrary {
    static let builtIn: [(name: String, symbol: String, tint: UIColor)] = [
        ("star", "star.fill", .systemYellow),
        ("heart", "heart.fill", .systemRed),
        ("check", "checkmark.seal.fill", .systemGreen),
        ("flag", "flag.fill", .systemOrange),
        ("bolt", "bolt.fill", .systemYellow),
        ("brain", "brain.head.profile", .systemPurple),
        ("book", "book.fill", .systemBlue),
        ("pin", "pin.fill", .systemRed),
        ("question", "questionmark.circle.fill", .systemTeal),
        ("exclaim", "exclamationmark.triangle.fill", .systemOrange),
    ]

    static func render(symbol: String, tint: UIColor, pointSize: CGFloat = 96) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        return UIImage(systemName: symbol, withConfiguration: config)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
    }
}
