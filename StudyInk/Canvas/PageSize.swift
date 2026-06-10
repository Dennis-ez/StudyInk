import UIKit

/// Page canvas dimensions in PencilKit points.
enum PageSize: String, CaseIterable, Codable, Identifiable {
    case letter, a4, screen, custom

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .letter: return CGSize(width: 765, height: 990)      // 8.5×11 at 90dpi-ish canvas scale
        case .a4: return CGSize(width: 744, height: 1052)
        case .screen:
            let bounds = UIScreen.main.bounds
            return CGSize(width: bounds.width, height: bounds.height)
        case .custom: return CGSize(width: 800, height: 1100)
        }
    }

    static func from(id: String?) -> PageSize {
        PageSize(rawValue: id ?? "letter") ?? .letter
    }
}
