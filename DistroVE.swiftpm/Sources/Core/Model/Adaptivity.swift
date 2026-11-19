import Foundation

/// 端末の性能の段階（Q81: どんな端末でも柔軟に）。重い処理の既定値を段階ごとに変える。
enum DeviceTier: String, Codable, CaseIterable, Sendable {
    case light
    case standard
    case high

    var label: String {
        switch self {
        case .light: return "軽め"
        case .standard: return "標準"
        case .high: return "高性能"
        }
    }

    var detail: String {
        switch self {
        case .light: return "プレビューを 1/2 にし、フル HD 以上の動画は軽い代替動画（プロキシ）で編集します。"
        case .standard: return "4K の動画はプロキシで編集します。"
        case .high: return "8K 以外はそのまま編集し、なめらかスローを最も細かく作ります。"
        }
    }

    /// メモリ（GB）・CPU の数・新しい GPU（A14・M1 以降）かどうかから段階を決める。
    static func classify(memoryGB: Double, cores: Int, modernGPU: Bool) -> DeviceTier {
        if memoryGB >= 7.5 && cores >= 8 && modernGPU { return .high }
        if memoryGB >= 3.5 && cores >= 6 { return .standard }
        return .light
    }

    var profile: DeviceProfile {
        switch self {
        case .light:
            return DeviceProfile(proxyAboveLongSide: 1300, proxyAboveFrameRate: 31, previewScale: 0.5, flowAccuracy: 1, sampleCount3D: 2)
        case .standard:
            return DeviceProfile(proxyAboveLongSide: 2000, proxyAboveFrameRate: 61, previewScale: 1, flowAccuracy: 2, sampleCount3D: 4)
        case .high:
            return DeviceProfile(proxyAboveLongSide: 4000, proxyAboveFrameRate: 121, previewScale: 1, flowAccuracy: 3, sampleCount3D: 4)
        }
    }
}

/// 段階ごとの既定値。
struct DeviceProfile: Equatable, Sendable {
    /// これより長い辺の動画は、取り込んだときにプロキシを作る
    var proxyAboveLongSide: Int
    /// これより高いフレームレートの動画もプロキシを作る
    var proxyAboveFrameRate: Double
    /// 編集中のプレビューの大きさ（1 = 原寸）
    var previewScale: Double
    /// オプティカルフローの細かさ（0〜3。大きいほど細かく遅い）
    var flowAccuracy: Int
    /// 3D の縁のなめらかさ（MSAA の数）
    var sampleCount3D: Int
}

/// 編集の経験に合わせた見せ方（Q15: 初心者からプロまで柔軟に）。
enum EditorLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case beginner
    case standard
    case pro

    var label: String {
        switch self {
        case .beginner: return "かんたん"
        case .standard: return "ふつう"
        case .pro: return "プロ"
        }
    }

    var detail: String {
        switch self {
        case .beginner: return "よく使う道具だけを出します（マスク・クロマキー・キーフレームなどは隠します）。"
        case .standard: return "すべての道具を出します。"
        case .pro: return "すべての道具を出し、クリップを選んだときはキーフレームを先頭に置きます。"
        }
    }

    private var order: Int {
        switch self {
        case .beginner: return 0
        case .standard: return 1
        case .pro: return 2
        }
    }

    static func < (lhs: EditorLevel, rhs: EditorLevel) -> Bool {
        return lhs.order < rhs.order
    }
}

/// 何も選んでいないときのツールバーの道具（Q66, Q70: 並べ替え・表示の切り替えができる）。
enum RootTool: String, Codable, CaseIterable, Sendable, Identifiable {
    case media
    case audio
    case text
    case stickers
    case object3D
    case subtitles
    case ai
    case split
    case filter
    case canvas
    case drawing
    case marker
    case reorder

    var id: String { return rawValue }

    var title: String {
        switch self {
        case .media: return "素材"
        case .audio: return "オーディオ"
        case .text: return "テキスト"
        case .stickers: return "ステッカー"
        case .object3D: return "3D"
        case .subtitles: return "字幕"
        case .ai: return "AI"
        case .split: return "分割"
        case .filter: return "フィルター"
        case .canvas: return "画面"
        case .drawing: return "手書き"
        case .marker: return "マーカー"
        case .reorder: return "並べ替え"
        }
    }

    var symbol: String {
        switch self {
        case .media: return "plus.rectangle.on.rectangle"
        case .audio: return "music.note"
        case .text: return "textformat"
        case .stickers: return "face.smiling"
        case .object3D: return "cube"
        case .subtitles: return "captions.bubble"
        case .ai: return "wand.and.stars"
        case .split: return "scissors"
        case .filter: return "camera.filters"
        case .canvas: return "aspectratio"
        case .drawing: return "pencil.tip"
        case .marker: return "bookmark"
        case .reorder: return "list.bullet"
        }
    }

    /// この段階から表示する（かんたんでは基本の道具だけ）。
    var minimumLevel: EditorLevel {
        switch self {
        case .media, .audio, .text, .stickers, .subtitles, .ai, .split, .filter, .canvas: return .beginner
        case .object3D, .drawing, .marker, .reorder: return .standard
        }
    }

    /// 並び順（保存した順に、新しく増えた道具を後ろへ足す）。
    static func ordered(_ saved: [String]) -> [RootTool] {
        var result: [RootTool] = []
        for raw in saved {
            if let tool = RootTool(rawValue: raw), !result.contains(tool) { result.append(tool) }
        }
        for tool in RootTool.allCases where !result.contains(tool) {
            result.append(tool)
        }
        return result
    }

    /// 表示する道具（段階と、利用者が隠したものを除く）。
    static func visible(order: [String], hidden: Set<String>, level: EditorLevel) -> [RootTool] {
        return RootTool.ordered(order).filter { $0.minimumLevel <= level && !hidden.contains($0.rawValue) }
    }
}
