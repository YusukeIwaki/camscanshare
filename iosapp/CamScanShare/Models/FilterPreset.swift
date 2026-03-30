import CoreImage
import Foundation

enum FilterPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case sharpen
    case bw
    case magic
    case whiteboard
    case vivid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "オリジナル"
        case .sharpen: "くっきり"
        case .bw: "白黒"
        case .magic: "マジック"
        case .whiteboard: "ホワイトボード"
        case .vivid: "鮮やか"
        }
    }
}
