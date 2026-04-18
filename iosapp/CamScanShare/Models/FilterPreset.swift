import CoreImage
import Foundation

enum FilterPreset: String, CaseIterable, Identifiable, Sendable {
    case original
    case sharpen
    case enhance
    case eco
    case bw
    case magic
    case magicPro = "magic_pro"
    case whiteboard
    case vivid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original: "オリジナル"
        case .sharpen: "くっきり"
        case .enhance: "強化"
        case .eco: "省エネ"
        case .bw: "白黒"
        case .magic: "マジック"
        case .magicPro: "Magic Pro"
        case .whiteboard: "ホワイトボード"
        case .vivid: "鮮やか"
        }
    }

    var thumbnailAssetName: String {
        switch self {
        case .original: "FilterOriginal"
        case .sharpen: "FilterSharpen"
        case .enhance: "FilterSharpen"
        case .eco: "FilterMagic"
        case .bw: "FilterBW"
        case .magic: "FilterMagic"
        case .magicPro: "FilterMagic"
        case .whiteboard: "FilterWhiteboard"
        case .vivid: "FilterVivid"
        }
    }
}
