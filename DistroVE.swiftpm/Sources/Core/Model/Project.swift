import Foundation

/// 画面の縦横比のプリセット。
enum AspectPreset: String, Codable, CaseIterable, Sendable {
    case landscape16x9
    case portrait9x16
    case square1x1
    case portrait4x5
    case landscape4x3
    case cinema21x9

    var label: String {
        switch self {
        case .landscape16x9: return "16:9 横"
        case .portrait9x16: return "9:16 縦"
        case .square1x1: return "1:1"
        case .portrait4x5: return "4:5"
        case .landscape4x3: return "4:3"
        case .cinema21x9: return "21:9"
        }
    }

    var ratio: Double {
        switch self {
        case .landscape16x9: return 16.0 / 9.0
        case .portrait9x16: return 9.0 / 16.0
        case .square1x1: return 1
        case .portrait4x5: return 4.0 / 5.0
        case .landscape4x3: return 4.0 / 3.0
        case .cinema21x9: return 21.0 / 9.0
        }
    }

    /// 短い辺を基準にしたピクセルサイズ（偶数にそろえる）。
    func size(shortSide: Int) -> (width: Int, height: Int) {
        let r: Double = ratio
        if r >= 1 {
            let w: Int = Int((Double(shortSide) * r).rounded())
            return (w - w % 2, shortSide - shortSide % 2)
        }
        let h: Int = Int((Double(shortSide) / r).rounded())
        return (shortSide - shortSide % 2, h - h % 2)
    }
}

/// キャンバス（出力画面）の設定。
struct CanvasSettings: Hashable, Codable, Sendable {
    var width: Int
    var height: Int
    var fps: Double
    var background: RGBA
    var aspect: AspectPreset

    init(aspect: AspectPreset, shortSide: Int = 1080, fps: Double = 30) {
        let size: (width: Int, height: Int) = aspect.size(shortSide: shortSide)
        self.width = size.width
        self.height = size.height
        self.fps = fps
        self.background = .black
        self.aspect = aspect
    }

    var isPortrait: Bool { return height > width }
}

/// プロジェクト（.disve ファイルの中身）。
struct Project: Identifiable, Codable, Sendable {
    static let currentFormatVersion: Int = 2
    static let fileExtension: String = "disve"

    var formatVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var canvas: CanvasSettings
    var media: [MediaAsset]
    var tracks: [Track]
    var markers: [TimelineMarker]
    var playRange: TimeRange?
    /// メイントラックを隙間なく詰める（マグネット）。オフにするとプロ向けの自由配置になる。
    var magneticMainTrack: Bool
    var lastExport: ExportSettings?
    var templateID: String?

    init(name: String, canvas: CanvasSettings) {
        self.formatVersion = Project.currentFormatVersion
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.canvas = canvas
        self.media = []
        self.tracks = [Track(kind: .video, name: "メイン")]
        self.markers = []
        self.playRange = nil
        self.magneticMainTrack = true
        self.lastExport = nil
        self.templateID = nil
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, createdAt, modifiedAt, canvas, media, tracks, markers
        case playRange, magneticMainTrack, lastExport, templateID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "無題"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
        canvas = try c.decodeIfPresent(CanvasSettings.self, forKey: .canvas) ?? CanvasSettings(aspect: .landscape16x9)
        media = try c.decodeIfPresent([MediaAsset].self, forKey: .media) ?? []
        tracks = try c.decodeIfPresent([Track].self, forKey: .tracks) ?? [Track(kind: .video, name: "メイン")]
        markers = try c.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        playRange = try c.decodeIfPresent(TimeRange.self, forKey: .playRange)
        magneticMainTrack = try c.decodeIfPresent(Bool.self, forKey: .magneticMainTrack) ?? true
        lastExport = try c.decodeIfPresent(ExportSettings.self, forKey: .lastExport)
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
    }

    // MARK: 参照

    func asset(_ id: UUID?) -> MediaAsset? {
        guard let id = id else { return nil }
        return media.first { $0.id == id }
    }

    func trackIndex(_ id: UUID) -> Int? {
        return tracks.firstIndex { $0.id == id }
    }

    /// クリップの位置（トラック番号とクリップ番号）。
    func locate(_ clipID: UUID) -> (track: Int, clip: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == clipID }) {
                return (t, c)
            }
        }
        return nil
    }

    func clip(_ id: UUID) -> Clip? {
        guard let loc = locate(id) else { return nil }
        return tracks[loc.track].clips[loc.clip]
    }

    /// 映像系トラックのうち一番下（メイン）。
    var mainTrackIndex: Int? {
        return tracks.firstIndex { $0.kind == .video }
    }

    /// 全体の長さ（クリップと字幕の終わりの最大値）。
    var duration: Time {
        var end: Time = .zero
        for track in tracks {
            if let last = track.clips.last, last.end > end { end = last.end }
            for clip in track.clips where clip.end > end {
                end = clip.end
            }
            if let cue = track.cues.last, cue.end > end { end = cue.end }
        }
        return end
    }

    var frameDuration: Time {
        return Time.frameDuration(fps: canvas.fps)
    }

    /// ビートマーカーの時刻（昇順）。
    var beatTimes: [Time] {
        var result: [Time] = []
        for marker in markers where marker.kind == .beat {
            result.append(marker.time)
        }
        result.sort()
        return result
    }

    var clipCount: Int {
        var count: Int = 0
        for track in tracks { count += track.clips.count }
        return count
    }
}

/// タイムライン上の目印。ビートマーカーもここに入る。
enum MarkerKind: String, Codable, Sendable {
    case user
    case beat
    case chapter
}

struct TimelineMarker: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var time: Time
    var kind: MarkerKind
    var label: String

    init(time: Time, kind: MarkerKind, label: String = "") {
        self.id = UUID()
        self.time = time
        self.kind = kind
        self.label = label
    }
}
