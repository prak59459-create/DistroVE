import Foundation

/// 3D の中身の種類（Q50: 本格的な 3D・モーショングラフィックス）。
enum Object3DKind: String, Codable, CaseIterable, Sendable {
    /// 押し出した立体文字
    case text
    /// 読み込んだ 3D モデル（USDZ・OBJ・STL・PLY など）
    case model
    case cube
    case sphere
    case cylinder
    case cone
    case torus

    var label: String {
        switch self {
        case .text: return "3D 文字"
        case .model: return "3D モデル"
        case .cube: return "立方体"
        case .sphere: return "球"
        case .cylinder: return "円柱"
        case .cone: return "円すい"
        case .torus: return "ドーナツ"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "textformat"
        case .model: return "arkit"
        case .cube: return "cube"
        case .sphere: return "circle.circle"
        case .cylinder: return "cylinder"
        case .cone: return "cone"
        case .torus: return "circle.dashed"
        }
    }

    static var primitives: [Object3DKind] { return [.cube, .sphere, .cylinder, .cone, .torus] }
}

/// 照明のプリセット。
enum Lighting3D: String, Codable, CaseIterable, Sendable {
    case studio
    case soft
    case dramatic
    case sunset
    case neon
    case backlit

    var label: String {
        switch self {
        case .studio: return "スタジオ"
        case .soft: return "やわらか"
        case .dramatic: return "ドラマチック"
        case .sunset: return "夕焼け"
        case .neon: return "ネオン"
        case .backlit: return "逆光"
        }
    }
}

/// 自動でつける動き（キーフレームと重ねて使える）。
enum Motion3D: String, Codable, CaseIterable, Sendable {
    case none
    /// 縦の軸で回り続ける
    case spin
    /// 横の軸で回り続ける
    case flip
    /// 左右にゆれる
    case swing
    /// ふわふわ浮く
    case float
    /// 斜めに転がる
    case tumble

    var label: String {
        switch self {
        case .none: return "なし"
        case .spin: return "回転"
        case .flip: return "縦回転"
        case .swing: return "ゆれ"
        case .float: return "浮遊"
        case .tumble: return "転がり"
        }
    }
}

/// 材質。色は 0〜1。
struct Material3D: Hashable, Codable, Sendable {
    /// 表面の色（文字では表と裏の面）
    var color: RGBA
    /// 文字の側面と面取りの色
    var sideColor: RGBA
    /// 0 = 樹脂のよう、1 = 金属
    var metallic: Double
    /// 0 = つるつる、1 = ざらざら
    var roughness: Double
    /// 自分で光る強さ（0〜1）
    var glow: Double

    init(color: RGBA = RGBA(0.96, 0.96, 0.98), sideColor: RGBA = RGBA(0.55, 0.58, 0.66),
         metallic: Double = 0, roughness: Double = 0.35, glow: Double = 0) {
        self.color = color
        self.sideColor = sideColor
        self.metallic = metallic
        self.roughness = roughness
        self.glow = glow
    }

    private enum CodingKeys: String, CodingKey {
        case color, sideColor, metallic, roughness, glow
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = c.value(.color, RGBA(0.96, 0.96, 0.98))
        sideColor = c.value(.sideColor, RGBA(0.55, 0.58, 0.66))
        metallic = c.value(.metallic, 0.0)
        roughness = c.value(.roughness, 0.35)
        glow = c.value(.glow, 0.0)
    }

    struct Preset: Sendable {
        let name: String
        let material: Material3D
    }

    static var presets: [Preset] {
        return [
            Preset(name: "白", material: Material3D()),
            Preset(name: "クローム", material: Material3D(color: RGBA(0.92, 0.93, 0.95), sideColor: RGBA(0.7, 0.72, 0.76), metallic: 1, roughness: 0.12)),
            Preset(name: "ゴールド", material: Material3D(color: RGBA(1.0, 0.78, 0.34), sideColor: RGBA(0.78, 0.52, 0.16), metallic: 1, roughness: 0.22)),
            Preset(name: "ネオン", material: Material3D(color: RGBA(1.0, 0.2, 0.75), sideColor: RGBA(0.2, 0.9, 1.0), metallic: 0, roughness: 0.3, glow: 0.8)),
            Preset(name: "マット黒", material: Material3D(color: RGBA(0.1, 0.1, 0.11), sideColor: RGBA(0.18, 0.18, 0.2), metallic: 0, roughness: 0.85)),
            Preset(name: "キャンディ", material: Material3D(color: RGBA(0.98, 0.32, 0.36), sideColor: RGBA(1.0, 0.9, 0.92), metallic: 0, roughness: 0.18))
        ]
    }
}

/// 3D の中身。位置・大きさ・回転（X・Y・Z）・不透明度は Transform を使い、キーフレームを付けられる。
struct Object3DContent: Hashable, Codable, Sendable {
    var kind: Object3DKind
    var text: String
    /// 空ならシステムのフォント
    var fontName: String
    var bold: Bool
    /// 押し出しの深さ（文字の高さに対する割合）
    var depth: Double
    /// 面取りの大きさ（文字の高さに対する割合）
    var bevel: Double
    var material: Material3D
    /// 読み込んだモデルの色やテクスチャをそのまま使う
    var useModelMaterials: Bool
    var lighting: Lighting3D
    var motion: Motion3D
    /// 1 = 標準（回転は 1 周 4 秒）
    var motionSpeed: Double
    /// 奥行きの位置（画面の高さに対する割合。正で手前）
    var positionZ: Param
    /// 画角（度）
    var fieldOfView: Double
    /// 画面の高さに対する大きさ
    var size: Double

    init(kind: Object3DKind, text: String = "3D") {
        self.kind = kind
        self.text = text
        self.fontName = ""
        self.bold = true
        self.depth = 0.25
        self.bevel = 0.02
        self.material = Material3D()
        self.useModelMaterials = true
        self.lighting = .studio
        self.motion = kind == .text ? .none : .spin
        self.motionSpeed = 1
        self.positionZ = Param(0)
        self.fieldOfView = 35
        self.size = kind == .text ? 0.22 : 0.4
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, fontName, bold, depth, bevel, material, useModelMaterials
        case lighting, motion, motionSpeed, positionZ, fieldOfView, size
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, Object3DKind.text)
        text = c.value(.text, "3D")
        fontName = c.value(.fontName, "")
        bold = c.value(.bold, true)
        depth = c.value(.depth, 0.25)
        bevel = c.value(.bevel, 0.02)
        material = c.value(.material, Material3D())
        useModelMaterials = c.value(.useModelMaterials, true)
        lighting = c.value(.lighting, Lighting3D.studio)
        motion = c.value(.motion, Motion3D.none)
        motionSpeed = c.value(.motionSpeed, 1.0)
        positionZ = c.value(.positionZ, Param(0))
        fieldOfView = c.value(.fieldOfView, 35.0)
        size = c.value(.size, 0.3)
    }

    static let depthRange: ClosedRange<Double> = 0.02...1.5
    static let bevelRange: ClosedRange<Double> = 0...0.08
    static let sizeRange: ClosedRange<Double> = 0.05...1.5
    static let fieldOfViewRange: ClosedRange<Double> = 15...90

    /// 形が変わる設定だけを並べた鍵（立体の作り直しが要るかどうかの判定に使う）。
    var geometryKey: String {
        switch kind {
        case .text:
            let d: String = String(format: "%.3f", depth)
            let b: String = String(format: "%.3f", bevel)
            return "text|" + text + "|" + fontName + "|" + (bold ? "b" : "r") + "|" + d + "|" + b
        default:
            return kind.rawValue
        }
    }

    /// 自動の動きによる回転（度）と上下のずれ（大きさに対する割合）。
    func motionOffset(at seconds: Double) -> (x: Double, y: Double, z: Double, lift: Double) {
        let s: Double = seconds * max(0.05, motionSpeed)
        let turn: Double = s * 90
        switch motion {
        case .none: return (0, 0, 0, 0)
        case .spin: return (0, turn, 0, 0)
        case .flip: return (turn, 0, 0, 0)
        case .swing: return (0, 25 * sin(s * Double.pi), 0, 0)
        case .float: return (6 * sin(s * Double.pi * 0.5), 12 * sin(s * Double.pi * 0.7), 0, 0.06 * sin(s * Double.pi))
        case .tumble: return (turn * 0.7, turn, turn * 0.35, 0)
        }
    }
}
