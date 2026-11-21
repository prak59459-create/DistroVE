import Foundation

/// 色の調整パラメーター（Q41）。
enum ColorSpecs {
    static let exposure = ParamSpec("exposure", "露出", -2, 2, 0, unit: "EV")
    static let brightness = ParamSpec("brightness", "明るさ", -0.5, 0.5, 0)
    static let contrast = ParamSpec("contrast", "コントラスト", 0.5, 1.5, 1)
    static let saturation = ParamSpec("saturation", "彩度", 0, 2, 1)
    static let vibrance = ParamSpec("vibrance", "自然な彩度", -1, 1, 0)
    static let temperature = ParamSpec("temperature", "色温度", -1, 1, 0)
    static let tint = ParamSpec("tint", "色かぶり", -1, 1, 0)
    static let highlights = ParamSpec("highlights", "ハイライト", 0, 1, 1)
    static let shadows = ParamSpec("shadows", "シャドウ", -1, 1, 0)
    static let hue = ParamSpec("hue", "色相", -180, 180, 0, unit: "°")
    static let sharpen = ParamSpec("sharpen", "シャープ", 0, 2, 0)
    static let vignette = ParamSpec("vignette", "周辺減光", 0, 2, 0)
    static let fade = ParamSpec("fade", "フェード", 0, 1, 0)

    static let all: [ParamSpec] = [
        exposure, brightness, contrast, saturation, vibrance, temperature, tint,
        highlights, shadows, hue, sharpen, vignette, fade
    ]
}

/// フィルター（内蔵の色味）または読み込んだ LUT。
struct LookSettings: Hashable, Codable, Sendable {
    /// "builtin:<名前>" または "lut:<UUID>"
    var id: String
    var intensity: Double

    init(id: String, intensity: Double = 1) {
        self.id = id
        self.intensity = intensity
    }

    var isBuiltin: Bool { return id.hasPrefix("builtin:") }
    var builtinName: String? {
        if !isBuiltin { return nil }
        return String(id.dropFirst("builtin:".count))
    }

    var lutID: UUID? {
        if !id.hasPrefix("lut:") { return nil }
        return UUID(uuidString: String(id.dropFirst("lut:".count)))
    }
}

/// トーンカーブ（点は 0〜1 の (入力, 出力)）。
struct CurveSet: Hashable, Codable, Sendable {
    var master: [Vec2]
    var red: [Vec2]
    var green: [Vec2]
    var blue: [Vec2]

    static let identity: [Vec2] = [Vec2(0, 0), Vec2(1, 1)]

    init() {
        master = CurveSet.identity
        red = CurveSet.identity
        green = CurveSet.identity
        blue = CurveSet.identity
    }

    var isIdentity: Bool {
        return CurveSet.isIdentity(master) && CurveSet.isIdentity(red)
            && CurveSet.isIdentity(green) && CurveSet.isIdentity(blue)
    }

    static func isIdentity(_ points: [Vec2]) -> Bool {
        for p in points where abs(p.x - p.y) > 0.0001 {
            return false
        }
        return true
    }

    /// よく使う形
    static func sCurve(_ amount: Double) -> CurveSet {
        var set = CurveSet()
        let a: Double = Num.clamp(amount, 0, 0.25)
        set.master = [Vec2(0, 0), Vec2(0.25, 0.25 - a), Vec2(0.75, 0.75 + a), Vec2(1, 1)]
        return set
    }
}

/// 重ね方（Q43: 不透明度・ブレンド）。
enum LayerBlend: String, Codable, CaseIterable, Sendable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case colorDodge
    case colorBurn
    case softLight
    case hardLight
    case difference
    case exclusion
    case add
    case hue
    case saturation
    case color
    case luminosity

    var label: String {
        switch self {
        case .normal: return "通常"
        case .multiply: return "乗算"
        case .screen: return "スクリーン"
        case .overlay: return "オーバーレイ"
        case .darken: return "比較（暗）"
        case .lighten: return "比較（明）"
        case .colorDodge: return "覆い焼き"
        case .colorBurn: return "焼き込み"
        case .softLight: return "ソフトライト"
        case .hardLight: return "ハードライト"
        case .difference: return "差の絶対値"
        case .exclusion: return "除外"
        case .add: return "加算"
        case .hue: return "色相"
        case .saturation: return "彩度"
        case .color: return "カラー"
        case .luminosity: return "輝度"
        }
    }
}

/// マスク（Q43）。座標はクリップの映像に対する割合（0〜1、左上が原点）。
enum MaskShape: String, Codable, CaseIterable, Sendable {
    case rectangle
    case ellipse
    case linear
    case mirror

    var label: String {
        switch self {
        case .rectangle: return "長方形"
        case .ellipse: return "円"
        case .linear: return "線形"
        case .mirror: return "帯"
        }
    }
}

struct MaskSettings: Hashable, Codable, Sendable {
    var shape: MaskShape
    var centerX: Param
    var centerY: Param
    var width: Param
    var height: Param
    var rotation: Param
    /// ぼかし（短辺に対する割合）
    var feather: Param
    var invert: Bool

    init(shape: MaskShape) {
        self.shape = shape
        self.centerX = Param(0.5)
        self.centerY = Param(0.5)
        self.width = Param(0.5)
        self.height = Param(0.5)
        self.rotation = Param(0)
        self.feather = Param(0.02)
        self.invert = false
    }
}

/// クロマキー（Q43）。
struct ChromaKeySettings: Hashable, Codable, Sendable {
    var color: RGBA
    /// 色相の許容幅（0〜1）
    var tolerance: Double
    /// 境界のなめらかさ
    var softness: Double
    /// 色かぶりの除去
    var spill: Double

    init(color: RGBA = .green) {
        self.color = color
        self.tolerance = 0.12
        self.softness = 0.08
        self.spill = 0.5
    }
}

/// 手ぶれ補正の解析結果（Q42）。素材時間の一定間隔ごとの補正量（画面に対する割合）。
struct StabilizationData: Hashable, Codable, Sendable {
    var strength: Double
    var interval: Time
    var offsets: [Vec2]
    /// 補正で画面端が見えないように拡大する倍率
    var zoom: Double

    init(interval: Time, offsets: [Vec2], strength: Double = 1, zoom: Double = 1.1) {
        self.strength = strength
        self.interval = interval
        self.offsets = offsets
        self.zoom = zoom
    }

    /// 素材時刻での補正量（線形補間）。
    func offset(atSource time: Time) -> Vec2 {
        if offsets.isEmpty || interval.ticks <= 0 { return .zero }
        let position: Double = Double(time.ticks) / Double(interval.ticks)
        if position <= 0 { return scaled(offsets[0]) }
        let index: Int = Int(position)
        if index >= offsets.count - 1 { return scaled(offsets[offsets.count - 1]) }
        let fraction: Double = position - Double(index)
        let a: Vec2 = offsets[index]
        let b: Vec2 = offsets[index + 1]
        return scaled(Vec2(Num.lerp(a.x, b.x, fraction), Num.lerp(a.y, b.y, fraction)))
    }

    private func scaled(_ v: Vec2) -> Vec2 {
        return Vec2(v.x * strength, v.y * strength)
    }
}
