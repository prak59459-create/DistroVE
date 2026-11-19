import Foundation

/// 速度設定から「タイムライン上の長さ」と「使う素材の長さ」の対応を求める。
/// 速度カーブは区分線形とし、合成時は一定速度の小区間に分けて AVFoundation に渡す。
struct SpeedMap {
    /// 合成用の一定速度区間（すべてクリップ先頭からの相対時刻）
    struct Segment: Equatable {
        var sourceOffset: Time
        var sourceDuration: Time
        var timelineOffset: Time
        var timelineDuration: Time
    }

    let settings: SpeedSettings
    private let points: [SpeedPoint]

    init(settings: SpeedSettings) {
        self.settings = settings
        if settings.hasCurve {
            self.points = SpeedMap.normalized(settings.curve)
        } else {
            let r: Double = Num.clamp(settings.rate, SpeedSettings.minRate, SpeedSettings.maxRate)
            self.points = [SpeedPoint(0, r), SpeedPoint(1, r)]
        }
    }

    /// 0 と 1 の端点をそろえ、範囲外の値を切りつめる。
    static func normalized(_ curve: [SpeedPoint]) -> [SpeedPoint] {
        var sorted: [SpeedPoint] = []
        for p in curve {
            let position: Double = Num.clamp(p.position, 0, 1)
            let rate: Double = Num.clamp(p.rate, SpeedSettings.minRate, SpeedSettings.maxRate)
            sorted.append(SpeedPoint(position, rate))
        }
        sorted.sort { $0.position < $1.position }
        if sorted.isEmpty { return [SpeedPoint(0, 1), SpeedPoint(1, 1)] }
        if sorted[0].position > 0 {
            sorted.insert(SpeedPoint(0, sorted[0].rate), at: 0)
        }
        if let last = sorted.last, last.position < 1 {
            sorted.append(SpeedPoint(1, last.rate))
        }
        return sorted
    }

    /// 正規化位置 u での速度。
    func rate(at u: Double) -> Double {
        let x: Double = Num.clamp(u, 0, 1)
        for i in 0..<(points.count - 1) {
            let a: SpeedPoint = points[i]
            let b: SpeedPoint = points[i + 1]
            if x <= b.position {
                let span: Double = b.position - a.position
                if span <= 0 { return b.rate }
                return Num.lerp(a.rate, b.rate, (x - a.position) / span)
            }
        }
        return points[points.count - 1].rate
    }

    /// 0〜u までの速度の積分（タイムライン長を 1 としたときの素材の進み）。
    func integral(to u: Double) -> Double {
        let x: Double = Num.clamp(u, 0, 1)
        var total: Double = 0
        for i in 0..<(points.count - 1) {
            let a: SpeedPoint = points[i]
            let b: SpeedPoint = points[i + 1]
            if x <= a.position { break }
            let upper: Double = min(x, b.position)
            let span: Double = upper - a.position
            if span <= 0 { continue }
            let rateAtUpper: Double = rate(at: upper)
            total += span * (a.rate + rateAtUpper) / 2
        }
        return total
    }

    /// 平均速度。
    var meanRate: Double {
        return max(SpeedSettings.minRate, integral(to: 1))
    }

    func sourceDuration(forTimeline duration: Time) -> Time {
        return duration.scaled(meanRate)
    }

    func timelineDuration(forSource duration: Time) -> Time {
        return duration.scaled(1 / meanRate)
    }

    /// クリップ先頭から t 進んだときの素材上の位置（先頭からの相対）。
    func sourceOffset(atTimeline t: Time, timelineDuration: Time) -> Time {
        if timelineDuration.ticks <= 0 { return .zero }
        let u: Double = Double(t.ticks) / Double(timelineDuration.ticks)
        return Time(ticks: Int64((integral(to: u) * Double(timelineDuration.ticks)).rounded()))
    }

    /// 合成用の区間。一定速度なら 1 区間、カーブなら細かく分ける。
    func segments(timelineDuration: Time, piecesPerSecond: Double = 8) -> [Segment] {
        if timelineDuration.ticks <= 0 { return [] }
        if !settings.hasCurve {
            let source: Time = sourceDuration(forTimeline: timelineDuration)
            return [Segment(sourceOffset: .zero, sourceDuration: source, timelineOffset: .zero, timelineDuration: timelineDuration)]
        }
        let count: Int = max(4, min(240, Int((timelineDuration.seconds * piecesPerSecond).rounded(.up))))
        var result: [Segment] = []
        var previousTimeline: Time = .zero
        var previousSource: Time = .zero
        for i in 1...count {
            let timeline: Time
            if i == count {
                timeline = timelineDuration
            } else {
                timeline = Time(ticks: timelineDuration.ticks * Int64(i) / Int64(count))
            }
            let source: Time = sourceOffset(atTimeline: timeline, timelineDuration: timelineDuration)
            let piece = Segment(
                sourceOffset: previousSource,
                sourceDuration: source - previousSource,
                timelineOffset: previousTimeline,
                timelineDuration: timeline - previousTimeline
            )
            if piece.timelineDuration.ticks > 0 && piece.sourceDuration.ticks > 0 {
                result.append(piece)
            }
            previousTimeline = timeline
            previousSource = source
        }
        return result
    }

    /// よく使う速度カーブ（CapCut などにある定番の形）。
    static let presets: [(name: String, points: [SpeedPoint])] = [
        ("モンタージュ", [SpeedPoint(0, 1), SpeedPoint(0.35, 3), SpeedPoint(0.5, 0.4), SpeedPoint(0.65, 3), SpeedPoint(1, 1)]),
        ("ヒーロー", [SpeedPoint(0, 2.5), SpeedPoint(0.4, 2.5), SpeedPoint(0.5, 0.3), SpeedPoint(0.6, 2.5), SpeedPoint(1, 2.5)]),
        ("弾丸", [SpeedPoint(0, 3), SpeedPoint(0.45, 0.25), SpeedPoint(0.55, 0.25), SpeedPoint(1, 3)]),
        ("ジャンプカット", [SpeedPoint(0, 0.5), SpeedPoint(0.3, 5), SpeedPoint(0.7, 5), SpeedPoint(1, 0.5)]),
        ("フラッシュイン", [SpeedPoint(0, 5), SpeedPoint(0.3, 1), SpeedPoint(1, 1)]),
        ("フラッシュアウト", [SpeedPoint(0, 1), SpeedPoint(0.7, 1), SpeedPoint(1, 5)])
    ]
}
