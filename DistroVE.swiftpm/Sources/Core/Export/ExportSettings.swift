import Foundation

enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc

    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "H.265 (HEVC)"
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case mp4
    case gif

    var label: String {
        switch self {
        case .mp4: return "MP4"
        case .gif: return "GIF"
        }
    }
}

/// 短い辺のピクセル数で表す解像度（Q73）。
enum ExportResolution: Int, Codable, CaseIterable, Sendable {
    case p480 = 480
    case p720 = 720
    case p1080 = 1080
    case p1440 = 1440
    case p2160 = 2160

    var label: String {
        switch self {
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .p2160: return "4K"
        }
    }
}

/// 書き出しの設定（Q72〜Q75）。
struct ExportSettings: Hashable, Codable, Sendable {
    var format: ExportFormat
    var codec: VideoCodec
    var resolution: ExportResolution
    var fps: Int
    /// nil なら解像度とフレームレートから自動で決める
    var bitrateMbps: Double?
    var includeAudio: Bool
    /// GIF のフレームレートと最大幅
    var gifFps: Int
    var gifMaxWidth: Int
    /// 書き出す範囲（nil なら全体）
    var range: TimeRange?

    init() {
        format = .mp4
        codec = .h264
        resolution = .p1080
        fps = 30
        bitrateMbps = nil
        includeAudio = true
        gifFps = 12
        gifMaxWidth = 480
        range = nil
    }

    private enum CodingKeys: String, CodingKey {
        case format, codec, resolution, fps, bitrateMbps, includeAudio, gifFps, gifMaxWidth, range
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = ExportSettings()
        format = c.value(.format, base.format)
        codec = c.value(.codec, base.codec)
        resolution = c.value(.resolution, base.resolution)
        fps = c.value(.fps, base.fps)
        bitrateMbps = c.optional(.bitrateMbps, Double.self)
        includeAudio = c.value(.includeAudio, base.includeAudio)
        gifFps = c.value(.gifFps, base.gifFps)
        gifMaxWidth = c.value(.gifMaxWidth, base.gifMaxWidth)
        range = c.optional(.range, TimeRange.self)
    }

    static let frameRates: [Int] = [24, 30, 60, 120]

    /// キャンバスの縦横比を保ったまま、短い辺を解像度に合わせた出力サイズ（偶数）。
    func outputSize(canvasWidth: Int, canvasHeight: Int) -> (width: Int, height: Int) {
        let shortSide: Int = resolution.rawValue
        let w: Double = Double(max(1, canvasWidth))
        let h: Double = Double(max(1, canvasHeight))
        var width: Int
        var height: Int
        if w >= h {
            height = shortSide
            width = Int((Double(shortSide) * w / h).rounded())
        } else {
            width = shortSide
            height = Int((Double(shortSide) * h / w).rounded())
        }
        width -= width % 2
        height -= height % 2
        return (max(2, width), max(2, height))
    }

    /// GIF の出力サイズ。
    func gifSize(canvasWidth: Int, canvasHeight: Int) -> (width: Int, height: Int) {
        let w: Double = Double(max(1, canvasWidth))
        let h: Double = Double(max(1, canvasHeight))
        let scale: Double = min(1, Double(gifMaxWidth) / max(w, h))
        var width: Int = Int((w * scale).rounded())
        var height: Int = Int((h * scale).rounded())
        width -= width % 2
        height -= height % 2
        return (max(2, width), max(2, height))
    }

    /// 自動のビットレート（bps）。YouTube の推奨値を目安にし、HEVC は約 6 割にする。
    func effectiveBitrate(width: Int, height: Int) -> Int {
        if let mbps = bitrateMbps { return Int(mbps * 1_000_000) }
        let pixels: Double = Double(width * height)
        let base1080: Double = 8_000_000
        var bitrate: Double = base1080 * pixels / (1920.0 * 1080.0)
        if fps > 30 { bitrate *= 1.5 }
        if fps > 60 { bitrate *= 1.4 }
        if codec == .hevc { bitrate *= 0.6 }
        return max(1_000_000, Int(bitrate))
    }

    /// 書き出し後のおおよそのファイルサイズ（バイト）。容量不足の警告に使う。
    func estimatedBytes(duration: Time, width: Int, height: Int) -> Int64 {
        let videoBits: Double = Double(effectiveBitrate(width: width, height: height))
        let audioBits: Double = includeAudio ? 192_000 : 0
        return Int64((videoBits + audioBits) / 8 * duration.seconds * 1.05)
    }
}

/// 投稿先向けのプリセット（Q75）。投稿はせず保存のみ（Q76）。
struct ExportPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String
    let aspect: AspectPreset?
    let settings: ExportSettings

    static var all: [ExportPreset] {
        return [youtube1080(), youtube4K(), tiktok(), instagramReels(), instagramFeed(), instagramSquare(), gif()]
    }

    static func youtube1080() -> ExportPreset {
        var s = ExportSettings()
        s.resolution = .p1080
        s.fps = 60
        return ExportPreset(id: "youtube1080", name: "YouTube 1080p", detail: "16:9 / 60fps / H.264", aspect: .landscape16x9, settings: s)
    }

    static func youtube4K() -> ExportPreset {
        var s = ExportSettings()
        s.resolution = .p2160
        s.fps = 30
        s.codec = .hevc
        return ExportPreset(id: "youtube4k", name: "YouTube 4K", detail: "16:9 / 30fps / HEVC", aspect: .landscape16x9, settings: s)
    }

    static func tiktok() -> ExportPreset {
        var s = ExportSettings()
        s.resolution = .p1080
        s.fps = 30
        return ExportPreset(id: "tiktok", name: "TikTok", detail: "9:16 / 1080×1920 / 30fps", aspect: .portrait9x16, settings: s)
    }

    static func instagramReels() -> ExportPreset {
        var s = ExportSettings()
        s.resolution = .p1080
        s.fps = 30
        return ExportPreset(id: "reels", name: "Instagram リール", detail: "9:16 / 1080×1920 / 30fps", aspect: .portrait9x16, settings: s)
    }

    static func instagramFeed() -> ExportPreset {
        var s = ExportSettings()
        s.resolution = .p1080
        s.fps = 30
        return ExportPreset(id: "feed", name: "Instagram フィード", detail: "4:5 / 1080×1350 / 30fps", aspect: .portrait4x5, settings: s)
    }

    static func instagramSquare() -> ExportPreset {
        var s = ExportSettings()
        s.resolution = .p1080
        s.fps = 30
        return ExportPreset(id: "square", name: "正方形", detail: "1:1 / 1080×1080 / 30fps", aspect: .square1x1, settings: s)
    }

    static func gif() -> ExportPreset {
        var s = ExportSettings()
        s.format = .gif
        s.includeAudio = false
        return ExportPreset(id: "gif", name: "GIF", detail: "最大 480px / 12fps", aspect: nil, settings: s)
    }
}

/// 端末の性能に応じて選べる設定を絞るための情報（4K・120fps は対応端末のみ）。
struct DeviceLimits: Hashable, Sendable {
    var maxResolution: ExportResolution
    var maxFps: Int
    var supportsHEVC: Bool

    static let unrestricted = DeviceLimits(maxResolution: .p2160, maxFps: 120, supportsHEVC: true)

    func allows(_ resolution: ExportResolution) -> Bool {
        return resolution.rawValue <= maxResolution.rawValue
    }

    func allows(fps: Int) -> Bool {
        return fps <= maxFps
    }

    /// 端末で選べない値を選べる範囲に直す。
    func clamp(_ settings: ExportSettings) -> ExportSettings {
        var s = settings
        if !allows(s.resolution) { s.resolution = maxResolution }
        if !allows(fps: s.fps) { s.fps = maxFps }
        if !supportsHEVC { s.codec = .h264 }
        return s
    }
}
