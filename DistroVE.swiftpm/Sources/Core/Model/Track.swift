import Foundation

/// トラックの種類。video は映像・画像・テキスト・図形などの見た目を持つクリップ全般を重ねられる。
enum TrackKind: String, Codable, Sendable {
    case video
    case audio
    case subtitle

    var label: String {
        switch self {
        case .video: return "映像"
        case .audio: return "音声"
        case .subtitle: return "字幕"
        }
    }
}

/// トラック。数に上限は設けない（Q31）。
struct Track: Identifiable, Codable, Sendable {
    var id: UUID
    var kind: TrackKind
    var name: String
    /// 開始時刻順・重なりなし
    var clips: [Clip]
    /// 字幕トラックのときの字幕
    var cues: [SubtitleCue]
    var subtitleStyle: SubtitleStyle
    /// 字幕全体のずれ補正（Q60: 音ズレは手動で調整）
    var subtitleOffset: Time
    var isMuted: Bool
    var isHidden: Bool
    var isLocked: Bool
    /// トラック全体の音量（1 = 100%）
    var volume: Double

    init(kind: TrackKind, name: String) {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.clips = []
        self.cues = []
        self.subtitleStyle = SubtitleStyle()
        self.subtitleOffset = .zero
        self.isMuted = false
        self.isHidden = false
        self.isLocked = false
        self.volume = 1
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, clips, cues, subtitleStyle, subtitleOffset, isMuted, isHidden, isLocked, volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = c.value(.kind, TrackKind.video)
        name = c.value(.name, "")
        clips = c.value(.clips, [Clip]())
        cues = c.value(.cues, [SubtitleCue]())
        subtitleStyle = c.value(.subtitleStyle, SubtitleStyle())
        subtitleOffset = c.value(.subtitleOffset, Time.zero)
        isMuted = c.value(.isMuted, false)
        isHidden = c.value(.isHidden, false)
        isLocked = c.value(.isLocked, false)
        volume = c.value(.volume, 1.0)
    }

    var isVisual: Bool { return kind == .video }

    var end: Time {
        var result: Time = .zero
        for clip in clips where clip.end > result {
            result = clip.end
        }
        return result
    }

    /// 区間が空いているか（except のクリップは無視）。
    func isFree(_ range: TimeRange, except: UUID? = nil) -> Bool {
        for clip in clips where clip.id != except {
            if clip.range.overlaps(range) { return false }
        }
        return true
    }

    mutating func sortClips() {
        clips.sort { $0.start < $1.start }
    }

    func clipIndex(at time: Time) -> Int? {
        return clips.firstIndex { $0.range.contains(time) }
    }
}
