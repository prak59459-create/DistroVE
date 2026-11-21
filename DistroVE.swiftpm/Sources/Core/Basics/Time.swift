import Foundation

/// タイムライン上の時刻と長さ。1 秒 = 60,000 ティック。
/// 24 / 25 / 30 / 48 / 50 / 60 / 120 / 240fps と 29.97fps を誤差なく表せる。
/// 浮動小数点の丸め誤差でクリップの間に 1 フレームの隙間ができるのを防ぐため、整数で持つ。
struct Time: Hashable, Comparable, Codable, Sendable {
    static let timescale: Int64 = 60_000
    static let zero = Time(ticks: 0)

    var ticks: Int64

    init(ticks: Int64) {
        self.ticks = ticks
    }

    init(seconds: Double) {
        let raw: Double = seconds * Double(Time.timescale)
        if raw.isNaN {
            self.ticks = 0
        } else if raw >= 9.0e18 {
            self.ticks = Int64.max / 4
        } else if raw <= -9.0e18 {
            self.ticks = Int64.min / 4
        } else {
            self.ticks = Int64(raw.rounded())
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        ticks = try container.decode(Int64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ticks)
    }

    var seconds: Double {
        return Double(ticks) / Double(Time.timescale)
    }

    static func < (lhs: Time, rhs: Time) -> Bool {
        return lhs.ticks < rhs.ticks
    }

    static func + (lhs: Time, rhs: Time) -> Time {
        return Time(ticks: lhs.ticks + rhs.ticks)
    }

    static func - (lhs: Time, rhs: Time) -> Time {
        return Time(ticks: lhs.ticks - rhs.ticks)
    }

    /// 長さを倍率で伸縮する（速度変更などに使う）。
    func scaled(_ factor: Double) -> Time {
        return Time(ticks: Int64((Double(ticks) * factor).rounded()))
    }

    func clamped(_ lower: Time, _ upper: Time) -> Time {
        if self < lower { return lower }
        if self > upper { return upper }
        return self
    }

    var isPositive: Bool { return ticks > 0 }

    /// 1 フレームの長さ。29.97 などの NTSC 系は fps に 29.97 を渡すと 1001/30000 秒になる。
    static func frameDuration(fps: Double) -> Time {
        if fps <= 0 { return Time(ticks: Time.timescale / 30) }
        let rounded: Double = fps.rounded()
        if abs(fps - rounded) < 0.001 {
            return Time(ticks: Int64((Double(Time.timescale) / rounded).rounded()))
        }
        // NTSC 系（29.97 → 30000/1001）
        let base: Double = (fps * 1.001).rounded()
        return Time(ticks: Int64((Double(Time.timescale) * 1001.0 / (base * 1000.0)).rounded()))
    }

    static func frames(_ count: Int, fps: Double) -> Time {
        return Time(ticks: frameDuration(fps: fps).ticks * Int64(count))
    }

    /// 最も近いフレーム境界に合わせる。
    func snappedToFrame(fps: Double) -> Time {
        let frame: Int64 = Time.frameDuration(fps: fps).ticks
        if frame <= 0 { return self }
        let index: Double = (Double(ticks) / Double(frame)).rounded()
        return Time(ticks: Int64(index) * frame)
    }

    func frameIndex(fps: Double) -> Int {
        let frame: Int64 = Time.frameDuration(fps: fps).ticks
        if frame <= 0 { return 0 }
        return Int(ticks / frame)
    }

    /// 「分:秒.フレーム」形式（1 時間以上は「時:分:秒.フレーム」）。
    func timecode(fps: Double) -> String {
        let negative: Bool = ticks < 0
        let absolute = Time(ticks: abs(ticks))
        let totalFrames: Int = absolute.frameIndex(fps: fps)
        let perSecond: Int = max(1, Int(fps.rounded()))
        let frames: Int = totalFrames % perSecond
        let totalSeconds: Int = Int(absolute.ticks / Time.timescale)
        let hours: Int = totalSeconds / 3600
        let minutes: Int = (totalSeconds / 60) % 60
        let secs: Int = totalSeconds % 60
        var text: String
        if hours > 0 {
            text = String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, frames)
        } else {
            text = String(format: "%02d:%02d.%02d", minutes, secs, frames)
        }
        if negative { text = "-" + text }
        return text
    }

    /// 「1:05」のような短い表示（ルーラー用）。
    var shortLabel: String {
        let totalSeconds: Int = Int(ticks / Time.timescale)
        let hours: Int = totalSeconds / 3600
        let minutes: Int = (totalSeconds / 60) % 60
        let secs: Int = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

/// 開始時刻と長さで表す区間。
struct TimeRange: Hashable, Codable, Sendable {
    var start: Time
    var duration: Time

    init(start: Time, duration: Time) {
        self.start = start
        self.duration = duration
    }

    init(start: Time, end: Time) {
        self.start = start
        self.duration = end - start
    }

    var end: Time { return start + duration }

    func contains(_ time: Time) -> Bool {
        return time >= start && time < end
    }

    func overlaps(_ other: TimeRange) -> Bool {
        return start < other.end && other.start < end
    }

    func intersection(_ other: TimeRange) -> TimeRange? {
        let lower: Time = max(start, other.start)
        let upper: Time = min(end, other.end)
        if upper <= lower { return nil }
        return TimeRange(start: lower, end: upper)
    }
}
