import Foundation

/// 映像エフェクトの種類（Q42 と phonk 系の演出）。
enum EffectKind: String, Codable, CaseIterable, Sendable {
    case blur
    case mosaic
    case glitch
    case rgbSplit
    case vhs
    case vignette
    case shake
    case flash
    case zoomPulse
    case grain
    case sharpen
    case bloom
    case zoomBlur
    case mono
    case invert
    case posterize
    case kaleidoscope
    case mirror

    var label: String {
        switch self {
        case .blur: return "ぼかし"
        case .mosaic: return "モザイク"
        case .glitch: return "グリッチ"
        case .rgbSplit: return "RGB ずらし"
        case .vhs: return "VHS"
        case .vignette: return "ビネット"
        case .shake: return "シェイク"
        case .flash: return "フラッシュ"
        case .zoomPulse: return "ズームパルス"
        case .grain: return "フィルム粒子"
        case .sharpen: return "シャープ"
        case .bloom: return "ブルーム"
        case .zoomBlur: return "ズームブラー"
        case .mono: return "モノクロ"
        case .invert: return "色反転"
        case .posterize: return "ポスタライズ"
        case .kaleidoscope: return "万華鏡"
        case .mirror: return "ミラー"
        }
    }

    var symbol: String {
        switch self {
        case .blur, .zoomBlur: return "drop"
        case .mosaic: return "square.grid.3x3"
        case .glitch, .rgbSplit, .vhs: return "waveform.path.ecg"
        case .vignette: return "circle.dashed"
        case .shake: return "iphone.radiowaves.left.and.right"
        case .flash: return "bolt"
        case .zoomPulse: return "plus.magnifyingglass"
        case .grain: return "circle.grid.cross"
        case .sharpen: return "triangle"
        case .bloom: return "sun.max"
        case .mono, .invert, .posterize: return "circle.lefthalf.filled"
        case .kaleidoscope: return "hexagon"
        case .mirror: return "rectangle.split.2x1"
        }
    }

    /// ビートに合わせて強さを脈打たせるのが似合うもの
    var supportsBeatSync: Bool {
        switch self {
        case .shake, .flash, .zoomPulse, .glitch, .rgbSplit, .zoomBlur: return true
        default: return false
        }
    }

    var specs: [ParamSpec] {
        switch self {
        case .blur: return [EffectSpecs.radius]
        case .mosaic: return [EffectSpecs.cellSize]
        case .glitch: return [EffectSpecs.intensity, EffectSpecs.frequency]
        case .rgbSplit: return [EffectSpecs.amount]
        case .vhs: return [EffectSpecs.intensity]
        case .vignette: return [EffectSpecs.intensity, EffectSpecs.radiusRatio]
        case .shake: return [EffectSpecs.intensity, EffectSpecs.frequency]
        case .flash: return [EffectSpecs.intensity]
        case .zoomPulse: return [EffectSpecs.amount]
        case .grain: return [EffectSpecs.intensity]
        case .sharpen: return [EffectSpecs.intensity]
        case .bloom: return [EffectSpecs.intensity, EffectSpecs.radius]
        case .zoomBlur: return [EffectSpecs.amount]
        case .mono: return [EffectSpecs.intensity]
        case .invert: return [EffectSpecs.intensity]
        case .posterize: return [EffectSpecs.levels]
        case .kaleidoscope: return [EffectSpecs.count]
        case .mirror: return [EffectSpecs.direction]
        }
    }
}

enum EffectSpecs {
    static let radius = ParamSpec("radius", "半径", 0, 60, 12)
    static let radiusRatio = ParamSpec("radiusRatio", "範囲", 0.2, 2, 1)
    static let cellSize = ParamSpec("cellSize", "粗さ", 2, 120, 24)
    static let intensity = ParamSpec("intensity", "強さ", 0, 1, 0.6)
    static let frequency = ParamSpec("frequency", "速さ", 0.5, 30, 8, unit: "Hz")
    static let amount = ParamSpec("amount", "量", 0, 1, 0.4)
    static let levels = ParamSpec("levels", "階調", 2, 16, 5)
    static let count = ParamSpec("count", "分割数", 2, 12, 6)
    static let direction = ParamSpec("direction", "向き（0=左右 1=上下）", 0, 1, 0)
    static let decay = ParamSpec("decay", "減衰", 0.05, 1, 0.25, unit: "秒")
}

/// クリップにかけたエフェクト 1 つ。
struct VideoEffect: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var kind: EffectKind
    var params: ParamSet
    var isEnabled: Bool
    /// ビートマーカーに合わせて強さを脈打たせる
    var beatSync: Bool

    init(kind: EffectKind) {
        self.id = UUID()
        self.kind = kind
        self.params = ParamSet()
        self.isEnabled = true
        self.beatSync = false
    }

    func value(_ spec: ParamSpec, at t: Time) -> Double {
        return params.value(spec, at: t)
    }
}

/// トランジションの種類（Q36 と 3D）。
enum TransitionKind: String, Codable, CaseIterable, Sendable {
    case fade
    case fadeBlack
    case flashWhite
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case wipeLeft
    case wipeRight
    case wipeUp
    case wipeDown
    case zoomIn
    case zoomOut
    case blur
    case glitch
    case spin
    case flip3D
    case cube3D
    /// 光学フローで切れ目の前後のコマを変形させてつなぐ（インタビューのジャンプカットなど、同じ場面をつなぐとき）
    case smoothCut

    var label: String {
        switch self {
        case .fade: return "クロスフェード"
        case .fadeBlack: return "黒フェード"
        case .flashWhite: return "白フラッシュ"
        case .slideLeft: return "スライド（左）"
        case .slideRight: return "スライド（右）"
        case .slideUp: return "スライド（上）"
        case .slideDown: return "スライド（下）"
        case .wipeLeft: return "ワイプ（左）"
        case .wipeRight: return "ワイプ（右）"
        case .wipeUp: return "ワイプ（上）"
        case .wipeDown: return "ワイプ（下）"
        case .zoomIn: return "ズームイン"
        case .zoomOut: return "ズームアウト"
        case .blur: return "ぼかし"
        case .glitch: return "グリッチ"
        case .spin: return "スピン"
        case .flip3D: return "3D フリップ"
        case .cube3D: return "3D キューブ"
        case .smoothCut: return "スムースカット"
        }
    }
}

/// 隣のクリップとのつなぎ。切れ目を中心に duration の間かかる。
struct ClipTransition: Hashable, Codable, Sendable {
    var kind: TransitionKind
    var duration: Time

    init(kind: TransitionKind, duration: Time = Time(seconds: 0.5)) {
        self.kind = kind
        self.duration = duration
    }
}

/// 重ねたクリップの出入りの動き。
enum AnimationKind: String, Codable, CaseIterable, Sendable {
    case fade
    case slideLeft
    case slideRight
    case slideUp
    case slideDown
    case zoom
    case pop
    case spin
    case blur

    var label: String {
        switch self {
        case .fade: return "フェード"
        case .slideLeft: return "左から"
        case .slideRight: return "右から"
        case .slideUp: return "下から"
        case .slideDown: return "上から"
        case .zoom: return "ズーム"
        case .pop: return "ポップ"
        case .spin: return "回転"
        case .blur: return "ぼかし"
        }
    }
}

struct ClipAnimation: Hashable, Codable, Sendable {
    var kind: AnimationKind
    var duration: Time

    init(kind: AnimationKind, duration: Time = Time(seconds: 0.4)) {
        self.kind = kind
        self.duration = duration
    }
}
