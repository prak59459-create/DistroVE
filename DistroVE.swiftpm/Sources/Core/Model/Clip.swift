import Foundation

/// クリップの種類。
enum ClipKind: String, Codable, CaseIterable, Sendable {
    case video
    case image
    case gif
    case audio
    case text
    case sticker
    case shape
    case solid
    /// 下にある映像全体（またはマスク範囲）に色やエフェクトをかける調整クリップ。モザイク枠もこれで作る。
    case adjustment
    /// 立体文字・3D モデル・基本の立体（Q50）
    case object3D

    var label: String {
        switch self {
        case .video: return "動画"
        case .image: return "画像"
        case .gif: return "GIF"
        case .audio: return "音声"
        case .text: return "テキスト"
        case .sticker: return "ステッカー"
        case .shape: return "図形"
        case .solid: return "単色"
        case .adjustment: return "調整"
        case .object3D: return "3D"
        }
    }

    var isVisual: Bool { return self != .audio }
    /// 素材ファイルの長さに縛られるか
    var usesMediaTime: Bool { return self == .video || self == .audio }
    var hasAudio: Bool { return self == .video || self == .audio }
}

/// キャンバスへの収め方。
enum FitMode: String, Codable, CaseIterable, Sendable {
    case fit
    case fill
    case stretch

    var label: String {
        switch self {
        case .fit: return "全体を表示"
        case .fill: return "画面を埋める"
        case .stretch: return "引き伸ばす"
        }
    }
}

/// 位置・大きさ・回転・不透明度・3D 回転・切り抜き・反転（Q35）。
struct Transform: Hashable, Codable, Sendable {
    /// キャンバス幅に対する中心からのずれ（右が正）
    var positionX: Param
    /// キャンバス高さに対する中心からのずれ（下が正）
    var positionY: Param
    /// 1 = 収め方どおりの大きさ
    var scale: Param
    /// 度（時計回りが正）
    var rotation: Param
    /// 0〜1
    var opacity: Param
    /// 3D の傾き（度）。X 軸まわり・Y 軸まわり
    var rotationX: Param
    var rotationY: Param
    /// 切り抜き（各辺の割合 0〜0.45）
    var cropLeft: Double
    var cropRight: Double
    var cropTop: Double
    var cropBottom: Double
    var flipHorizontal: Bool
    var flipVertical: Bool

    init() {
        positionX = Param(0)
        positionY = Param(0)
        scale = Param(1)
        rotation = Param(0)
        opacity = Param(1)
        rotationX = Param(0)
        rotationY = Param(0)
        cropLeft = 0
        cropRight = 0
        cropTop = 0
        cropBottom = 0
        flipHorizontal = false
        flipVertical = false
    }

    private enum CodingKeys: String, CodingKey {
        case positionX, positionY, scale, rotation, opacity, rotationX, rotationY
        case cropLeft, cropRight, cropTop, cropBottom, flipHorizontal, flipVertical
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positionX = c.value(.positionX, Param(0))
        positionY = c.value(.positionY, Param(0))
        scale = c.value(.scale, Param(1))
        rotation = c.value(.rotation, Param(0))
        opacity = c.value(.opacity, Param(1))
        rotationX = c.value(.rotationX, Param(0))
        rotationY = c.value(.rotationY, Param(0))
        cropLeft = c.value(.cropLeft, 0.0)
        cropRight = c.value(.cropRight, 0.0)
        cropTop = c.value(.cropTop, 0.0)
        cropBottom = c.value(.cropBottom, 0.0)
        flipHorizontal = c.value(.flipHorizontal, false)
        flipVertical = c.value(.flipVertical, false)
    }

    var hasCrop: Bool {
        return cropLeft > 0.0001 || cropRight > 0.0001 || cropTop > 0.0001 || cropBottom > 0.0001
    }

    var isAnimated: Bool {
        return positionX.isAnimated || positionY.isAnimated || scale.isAnimated || rotation.isAnimated
            || opacity.isAnimated || rotationX.isAnimated || rotationY.isAnimated
    }

    func split(at t: Time) -> (Transform, Transform) {
        var left: Transform = self
        var right: Transform = self
        let px: (Param, Param) = positionX.split(at: t)
        let py: (Param, Param) = positionY.split(at: t)
        let sc: (Param, Param) = scale.split(at: t)
        let ro: (Param, Param) = rotation.split(at: t)
        let op: (Param, Param) = opacity.split(at: t)
        let rx: (Param, Param) = rotationX.split(at: t)
        let ry: (Param, Param) = rotationY.split(at: t)
        left.positionX = px.0
        right.positionX = px.1
        left.positionY = py.0
        right.positionY = py.1
        left.scale = sc.0
        right.scale = sc.1
        left.rotation = ro.0
        right.rotation = ro.1
        left.opacity = op.0
        right.opacity = op.1
        left.rotationX = rx.0
        right.rotationX = rx.1
        left.rotationY = ry.0
        right.rotationY = ry.1
        return (left, right)
    }

    func shifted(by delta: Time) -> Transform {
        var result: Transform = self
        result.positionX = positionX.shifted(by: delta)
        result.positionY = positionY.shifted(by: delta)
        result.scale = scale.shifted(by: delta)
        result.rotation = rotation.shifted(by: delta)
        result.opacity = opacity.shifted(by: delta)
        result.rotationX = rotationX.shifted(by: delta)
        result.rotationY = rotationY.shifted(by: delta)
        return result
    }
}

/// 速度の設定（Q34: 倍速・スロー・逆再生・速度カーブ・静止）。
struct SpeedSettings: Hashable, Codable, Sendable {
    /// 一定速度のときの倍率
    var rate: Double
    /// 速度カーブ（空なら一定速度）。position はクリップ内の位置 0〜1
    var curve: [SpeedPoint]
    var reversed: Bool
    /// 速度を変えても声の高さを保つ
    var preservePitch: Bool
    /// スローのとき、オプティカルフローで作ったコマの間を使う（Q99）
    var smooth: Bool

    init(rate: Double = 1) {
        self.rate = rate
        self.curve = []
        self.reversed = false
        self.preservePitch = true
        self.smooth = false
    }

    private enum CodingKeys: String, CodingKey {
        case rate, curve, reversed, preservePitch, smooth
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rate = c.value(.rate, 1.0)
        curve = c.value(.curve, [SpeedPoint]())
        reversed = c.value(.reversed, false)
        preservePitch = c.value(.preservePitch, true)
        smooth = c.value(.smooth, false)
    }

    /// いちばん遅いところの倍率（なめらかスローでどれだけコマを足すかの目安）。
    var slowestRate: Double {
        if !hasCurve { return rate }
        var slowest: Double = rate
        for point in curve {
            slowest = min(slowest, point.rate)
        }
        return slowest
    }

    /// なめらかスローで足すコマの倍数（2・4・8）。
    var suggestedInterpolationFactor: Int {
        let slowest: Double = max(0.01, slowestRate)
        if slowest >= 0.75 { return 2 }
        if slowest >= 0.35 { return 4 }
        return 8
    }

    var hasCurve: Bool { return curve.count >= 2 }
    var isDefault: Bool { return !hasCurve && abs(rate - 1) < 0.0001 && !reversed }

    static let minRate: Double = 0.1
    static let maxRate: Double = 100
}

struct SpeedPoint: Hashable, Codable, Sendable {
    var position: Double
    var rate: Double

    init(_ position: Double, _ rate: Double) {
        self.position = position
        self.rate = rate
    }
}

/// タイムライン上の 1 クリップ。
struct Clip: Identifiable, Codable, Sendable {
    var id: UUID
    var kind: ClipKind
    var mediaID: UUID?
    var name: String
    /// タイムライン上の開始位置
    var start: Time
    /// タイムライン上の長さ（速度変更後）
    var duration: Time
    /// 素材の中での開始位置（イン点）
    var sourceStart: Time
    var speed: SpeedSettings
    var transform: Transform
    var fitMode: FitMode
    /// 色の調整（明るさ・コントラスト・彩度・色温度など）
    var color: ParamSet
    /// フィルター（内蔵の色味）や読み込んだ LUT
    var look: LookSettings?
    /// トーンカーブ
    var curves: CurveSet?
    var effects: [VideoEffect]
    var mask: MaskSettings?
    var chromaKey: ChromaKeySettings?
    var blend: LayerBlend
    /// 端末内 AI で人物以外を消す
    var removeBackground: Bool
    var stabilization: StabilizationData?
    /// 直前のクリップからのトランジション（メイントラック）
    var transitionIn: ClipTransition?
    /// 重ねたクリップの出入りの動き
    var animationIn: ClipAnimation?
    var animationOut: ClipAnimation?
    var audio: AudioSettings
    var text: TextContent?
    var shape: ShapeContent?
    var solidColor: RGBA?
    var object3D: Object3DContent?

    init(kind: ClipKind, name: String, start: Time, duration: Time) {
        self.id = UUID()
        self.kind = kind
        self.mediaID = nil
        self.name = name
        self.start = start
        self.duration = duration
        self.sourceStart = .zero
        self.speed = SpeedSettings()
        self.transform = Transform()
        self.fitMode = .fit
        self.color = ParamSet()
        self.look = nil
        self.curves = nil
        self.effects = []
        self.mask = nil
        self.chromaKey = nil
        self.blend = .normal
        self.removeBackground = false
        self.stabilization = nil
        self.transitionIn = nil
        self.animationIn = nil
        self.animationOut = nil
        self.audio = AudioSettings()
        self.text = nil
        self.shape = nil
        self.solidColor = nil
        self.object3D = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, mediaID, name, start, duration, sourceStart, speed, transform, fitMode
        case color, look, curves, effects, mask, chromaKey, blend, removeBackground, stabilization
        case transitionIn, animationIn, animationOut, audio, text, shape, solidColor, object3D
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        start = try c.decode(Time.self, forKey: .start)
        duration = try c.decode(Time.self, forKey: .duration)
        mediaID = c.optional(.mediaID, UUID.self)
        name = c.value(.name, "")
        sourceStart = c.value(.sourceStart, Time.zero)
        speed = c.value(.speed, SpeedSettings())
        transform = c.value(.transform, Transform())
        fitMode = c.value(.fitMode, FitMode.fit)
        color = c.value(.color, ParamSet())
        look = c.optional(.look, LookSettings.self)
        curves = c.optional(.curves, CurveSet.self)
        effects = c.value(.effects, [VideoEffect]())
        mask = c.optional(.mask, MaskSettings.self)
        chromaKey = c.optional(.chromaKey, ChromaKeySettings.self)
        blend = c.value(.blend, LayerBlend.normal)
        removeBackground = c.value(.removeBackground, false)
        stabilization = c.optional(.stabilization, StabilizationData.self)
        transitionIn = c.optional(.transitionIn, ClipTransition.self)
        animationIn = c.optional(.animationIn, ClipAnimation.self)
        animationOut = c.optional(.animationOut, ClipAnimation.self)
        audio = c.value(.audio, AudioSettings())
        text = c.optional(.text, TextContent.self)
        shape = c.optional(.shape, ShapeContent.self)
        solidColor = c.optional(.solidColor, RGBA.self)
        object3D = c.optional(.object3D, Object3DContent.self)
    }

    var end: Time { return start + duration }
    var range: TimeRange { return TimeRange(start: start, duration: duration) }

    /// タイムライン時刻をクリップ内の時刻（キーフレームの基準）に直す。
    func localTime(_ timelineTime: Time) -> Time {
        return (timelineTime - start).clamped(.zero, duration)
    }

    /// クリップが使う素材の長さ（速度変更前）。
    var sourceDuration: Time {
        return SpeedMap(settings: speed).sourceDuration(forTimeline: duration)
    }

    var sourceEnd: Time { return sourceStart + sourceDuration }

    var hasVisualContent: Bool { return kind.isVisual }

    /// 表示用の短い説明（速度・エフェクトのバッジ）。
    var badges: [String] {
        var result: [String] = []
        if speed.hasCurve {
            result.append("カーブ")
        } else if abs(speed.rate - 1) > 0.001 {
            result.append(String(format: "%.2gx", speed.rate))
        }
        if speed.reversed { result.append("逆") }
        if speed.smooth { result.append("なめらか") }
        if !effects.isEmpty { result.append("FX\(effects.count)") }
        if look != nil || !color.values.isEmpty { result.append("色") }
        if transform.isAnimated || color.isAnimated { result.append("◆") }
        if removeBackground { result.append("背景除去") }
        if chromaKey != nil { result.append("キー") }
        if stabilization != nil { result.append("補正") }
        return result
    }
}
