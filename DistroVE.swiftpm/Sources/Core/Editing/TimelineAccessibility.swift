import Foundation

/// タイムラインの読み上げ（Q69: VoiceOver でクリップ単位に操作できるように）。
enum TimelineAccessibility {
    /// クリップの名前（種類と名前）と値（位置・長さ・速度などの印）。
    static func describe(_ clip: Clip, track: Track) -> (label: String, value: String) {
        let kind: String = track.kind == .audio && clip.kind == .audio ? "音声" : clip.kind.label
        let name: String = clip.name.isEmpty ? kind : clip.name
        var value: String = clip.start.shortLabel + " から " + TimelineAccessibility.length(clip.duration)
        let badges: [String] = clip.badges
        if !badges.isEmpty {
            value += "、" + badges.joined(separator: "・")
        }
        return (kind + "：" + name, value)
    }

    /// 「3.5 秒」「1 分 5 秒」のような読みやすい長さ。
    static func length(_ time: Time) -> String {
        let seconds: Double = max(0, time.seconds)
        if seconds < 60 {
            let rounded: Double = (seconds * 10).rounded() / 10
            let text: String = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            return text + " 秒"
        }
        let minutes: Int = Int(seconds) / 60
        let rest: Int = Int(seconds) % 60
        return rest == 0 ? "\(minutes) 分" : "\(minutes) 分 \(rest) 秒"
    }
}
