import Foundation

enum TextAlign: String, Codable, CaseIterable, Sendable {
    case left
    case center
    case right

    var label: String {
        switch self {
        case .left: return "左"
        case .center: return "中央"
        case .right: return "右"
        }
    }
}

/// テキストの動き（Q46: アニメーション）。
enum TextAnimation: String, Codable, CaseIterable, Sendable {
    case none
    case fade
    case typewriter
    case pop
    case slideUp
    case bounce
    case glitch
    case blurIn

    var label: String {
        switch self {
        case .none: return "なし"
        case .fade: return "フェード"
        case .typewriter: return "タイプライター"
        case .pop: return "ポップ"
        case .slideUp: return "せり上がり"
        case .bounce: return "バウンド"
        case .glitch: return "グリッチ"
        case .blurIn: return "ぼかしイン"
        }
    }
}

/// テキスト（Q46）。大きさや太さはキャンバスの高さに対する割合で持つので、解像度を変えても見た目が変わらない。
struct TextContent: Hashable, Codable, Sendable {
    var string: String
    /// フォント名（空ならシステムフォント）
    var fontName: String
    /// 文字の大きさ（キャンバス高さに対する割合）
    var size: Double
    var bold: Bool
    var italic: Bool
    var color: RGBA
    var align: TextAlign
    var strokeColor: RGBA
    /// 縁取りの太さ（文字の大きさに対する割合。0 で縁取りなし）
    var strokeWidth: Double
    var shadowColor: RGBA
    /// 影のぼかし（文字の大きさに対する割合。0 で影なし）
    var shadowBlur: Double
    var shadowOffset: Double
    /// 背景の帯（a が 0 なら無し）
    var backgroundColor: RGBA
    var backgroundPadding: Double
    var cornerRadius: Double
    var lineSpacing: Double
    var kerning: Double
    var animation: TextAnimation
    var animationDuration: Double
    /// 折り返し幅（キャンバス幅に対する割合）
    var maxWidth: Double

    init(string: String) {
        self.string = string
        self.fontName = ""
        self.size = 0.07
        self.bold = true
        self.italic = false
        self.color = .white
        self.align = .center
        self.strokeColor = .black
        self.strokeWidth = 0
        self.shadowColor = RGBA(0, 0, 0, 0.6)
        self.shadowBlur = 0.08
        self.shadowOffset = 0.04
        self.backgroundColor = .clear
        self.backgroundPadding = 0.3
        self.cornerRadius = 0.2
        self.lineSpacing = 0.1
        self.kerning = 0
        self.animation = .none
        self.animationDuration = 0.5
        self.maxWidth = 0.9
    }

    private enum CodingKeys: String, CodingKey {
        case string, fontName, size, bold, italic, color, align, strokeColor, strokeWidth
        case shadowColor, shadowBlur, shadowOffset, backgroundColor, backgroundPadding, cornerRadius
        case lineSpacing, kerning, animation, animationDuration, maxWidth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = TextContent(string: "")
        string = c.value(.string, "")
        fontName = c.value(.fontName, base.fontName)
        size = c.value(.size, base.size)
        bold = c.value(.bold, base.bold)
        italic = c.value(.italic, base.italic)
        color = c.value(.color, base.color)
        align = c.value(.align, base.align)
        strokeColor = c.value(.strokeColor, base.strokeColor)
        strokeWidth = c.value(.strokeWidth, base.strokeWidth)
        shadowColor = c.value(.shadowColor, base.shadowColor)
        shadowBlur = c.value(.shadowBlur, base.shadowBlur)
        shadowOffset = c.value(.shadowOffset, base.shadowOffset)
        backgroundColor = c.value(.backgroundColor, base.backgroundColor)
        backgroundPadding = c.value(.backgroundPadding, base.backgroundPadding)
        cornerRadius = c.value(.cornerRadius, base.cornerRadius)
        lineSpacing = c.value(.lineSpacing, base.lineSpacing)
        kerning = c.value(.kerning, base.kerning)
        animation = c.value(.animation, base.animation)
        animationDuration = c.value(.animationDuration, base.animationDuration)
        maxWidth = c.value(.maxWidth, base.maxWidth)
    }
}

/// テキストのスタイル見本（Q46: テンプレート）。
enum TextPresets {
    struct Preset: Sendable {
        let id: String
        let name: String
        let content: TextContent
    }

    static var all: [Preset] {
        return [simple(), outline(), band(), neon(), pop(), cinema(), caption(), phonk()]
    }

    static func simple() -> Preset {
        let t = TextContent(string: "テキスト")
        return Preset(id: "simple", name: "シンプル", content: t)
    }

    static func outline() -> Preset {
        var t = TextContent(string: "テロップ")
        t.color = .white
        t.strokeColor = .black
        t.strokeWidth = 0.14
        t.shadowBlur = 0
        return Preset(id: "outline", name: "縁取り", content: t)
    }

    static func band() -> Preset {
        var t = TextContent(string: "見出し")
        t.backgroundColor = RGBA(0.05, 0.05, 0.05, 0.75)
        t.shadowBlur = 0
        t.size = 0.055
        return Preset(id: "band", name: "帯付き", content: t)
    }

    static func neon() -> Preset {
        var t = TextContent(string: "NEON")
        t.color = RGBA(0.6, 1, 1)
        t.shadowColor = RGBA(0, 0.9, 1, 1)
        t.shadowBlur = 0.35
        t.shadowOffset = 0
        t.animation = .fade
        return Preset(id: "neon", name: "ネオン", content: t)
    }

    static func pop() -> Preset {
        var t = TextContent(string: "POP!")
        t.color = RGBA.yellow
        t.strokeColor = RGBA(0.9, 0.1, 0.3)
        t.strokeWidth = 0.16
        t.size = 0.1
        t.animation = .pop
        return Preset(id: "pop", name: "ポップ", content: t)
    }

    static func cinema() -> Preset {
        var t = TextContent(string: "CINEMATIC")
        t.bold = false
        t.kerning = 0.25
        t.size = 0.05
        t.shadowBlur = 0
        t.animation = .blurIn
        t.animationDuration = 1
        return Preset(id: "cinema", name: "シネマ", content: t)
    }

    static func caption() -> Preset {
        var t = TextContent(string: "字幕スタイル")
        t.size = 0.05
        t.strokeWidth = 0.12
        t.shadowBlur = 0
        t.animation = .typewriter
        return Preset(id: "caption", name: "タイプ", content: t)
    }

    static func phonk() -> Preset {
        var t = TextContent(string: "PHONK")
        t.color = RGBA(1, 0.15, 0.2)
        t.strokeColor = .black
        t.strokeWidth = 0.1
        t.size = 0.12
        t.animation = .glitch
        t.italic = true
        return Preset(id: "phonk", name: "phonk", content: t)
    }
}

/// 図形（Q47: 矢印・図形）。
enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
    case star
    case arrow
    case line

    var label: String {
        switch self {
        case .rectangle: return "四角"
        case .roundedRectangle: return "角丸"
        case .ellipse: return "円"
        case .triangle: return "三角"
        case .star: return "星"
        case .arrow: return "矢印"
        case .line: return "線"
        }
    }
}

struct ShapeContent: Hashable, Codable, Sendable {
    var kind: ShapeKind
    var fill: RGBA
    var stroke: RGBA
    /// 線の太さ（図形の短辺に対する割合）
    var strokeWidth: Double
    /// 幅 / 高さ
    var aspect: Double
    /// キャンバス短辺に対する大きさ
    var size: Double

    init(kind: ShapeKind) {
        self.kind = kind
        self.fill = kind == .arrow || kind == .line ? RGBA(1, 0.25, 0.2) : RGBA(1, 1, 1, 0)
        self.stroke = RGBA(1, 0.25, 0.2)
        self.strokeWidth = 0.06
        self.aspect = kind == .arrow ? 2.5 : (kind == .line ? 8 : 1)
        self.size = 0.3
    }
}

/// イコライザーの型（Q53）。
enum EQPreset: String, Codable, CaseIterable, Sendable {
    case flat
    case voice
    case bassBoost
    case trebleBoost
    case lofi
    case telephone

    var label: String {
        switch self {
        case .flat: return "なし"
        case .voice: return "声をくっきり"
        case .bassBoost: return "低音強調"
        case .trebleBoost: return "高音強調"
        case .lofi: return "Lo-Fi"
        case .telephone: return "電話"
        }
    }
}

/// ボイスチェンジ（Q53）。
enum VoicePreset: String, Codable, CaseIterable, Sendable {
    case none
    case chipmunk
    case deep
    case robot
    case alien
    case radio
    case echo

    var label: String {
        switch self {
        case .none: return "なし"
        case .chipmunk: return "高い声"
        case .deep: return "低い声"
        case .robot: return "ロボット"
        case .alien: return "宇宙人"
        case .radio: return "無線"
        case .echo: return "エコー"
        }
    }
}

/// 端末内で事前に処理する音声加工。処理済みファイルは設定の署名と一緒に持ち、設定が変わったら作り直す。
struct AudioProcessing: Hashable, Codable, Sendable {
    var eq: EQPreset
    var voice: VoicePreset
    /// ノイズ除去の強さ（0〜1）
    var denoise: Double
    var renderedPath: String?
    var renderedSignature: String?

    init() {
        eq = .flat
        voice = .none
        denoise = 0
        renderedPath = nil
        renderedSignature = nil
    }

    var signature: String {
        return "\(eq.rawValue)|\(voice.rawValue)|\(Int((denoise * 100).rounded()))"
    }

    var isActive: Bool {
        return eq != .flat || voice != .none || denoise > 0.001
    }

    var isRenderedUpToDate: Bool {
        return renderedPath != nil && renderedSignature == signature
    }
}

/// クリップの音声設定（Q51, Q52）。
struct AudioSettings: Hashable, Codable, Sendable {
    /// 1 = 100%（最大 2 = 200%）。キーフレーム可
    var volume: Param
    var fadeIn: Time
    var fadeOut: Time
    var isMuted: Bool
    /// 音量の自動そろえで決めた倍率
    var gain: Double
    var processing: AudioProcessing

    init() {
        volume = Param(1)
        fadeIn = .zero
        fadeOut = .zero
        isMuted = false
        gain = 1
        processing = AudioProcessing()
    }

    private enum CodingKeys: String, CodingKey {
        case volume, fadeIn, fadeOut, isMuted, gain, processing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = c.value(.volume, Param(1))
        fadeIn = c.value(.fadeIn, Time.zero)
        fadeOut = c.value(.fadeOut, Time.zero)
        isMuted = c.value(.isMuted, false)
        gain = c.value(.gain, 1.0)
        processing = c.value(.processing, AudioProcessing())
    }

    /// クリップ内時刻での実効音量（フェードと自動そろえを含む）。
    func level(at local: Time, clipDuration: Time) -> Double {
        if isMuted { return 0 }
        var v: Double = volume.value(at: local) * gain
        if fadeIn.isPositive && local < fadeIn {
            v *= Double(local.ticks) / Double(fadeIn.ticks)
        }
        let remaining: Time = clipDuration - local
        if fadeOut.isPositive && remaining < fadeOut {
            v *= max(0, Double(remaining.ticks) / Double(fadeOut.ticks))
        }
        return max(0, v)
    }
}
