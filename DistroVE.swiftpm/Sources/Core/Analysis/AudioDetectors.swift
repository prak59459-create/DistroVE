import Foundation

/// 無音区間の検出（Q45: 無音カット）。
enum SilenceDetector {
    struct Options: Sendable {
        /// これより小さい音を無音とみなす（dBFS）。nil なら素材の雑音レベルから自動で決める
        var thresholdDB: Double?
        /// これより短い無音は残す（秒）
        var minSilence: Double
        /// 切った前後に残す余白（秒）
        var padding: Double

        init(thresholdDB: Double? = nil, minSilence: Double = 0.6, padding: Double = 0.12) {
            self.thresholdDB = thresholdDB
            self.minSilence = minSilence
            self.padding = padding
        }
    }

    /// 自動のしきい値：静かな 10% の音量 + 12dB（-55〜-25dB の範囲）。
    static func autoThreshold(_ features: AudioFeatures) -> Double {
        if features.rms.isEmpty { return -40 }
        var levels: [Double] = []
        levels.reserveCapacity(features.rms.count)
        for v in features.rms {
            levels.append(Num.dB(fromLinear: Double(v)))
        }
        levels.sort()
        let floor: Double = levels[levels.count / 10]
        return Num.clamp(floor + 12, -55, -25)
    }

    /// 無音区間（秒）の一覧。
    static func detect(_ features: AudioFeatures, options: Options = Options()) -> [ClosedRange<Double>] {
        let threshold: Double = options.thresholdDB ?? autoThreshold(features)
        let linear: Float = Float(Num.linear(fromDB: threshold))
        let fr: Double = features.frameRate
        var ranges: [ClosedRange<Double>] = []
        var runStart: Int = -1
        let n: Int = features.rms.count
        for i in 0...n {
            let silent: Bool = i < n && features.rms[i] < linear
            if silent {
                if runStart < 0 { runStart = i }
            } else if runStart >= 0 {
                let start: Double = Double(runStart) / fr
                let end: Double = Double(i) / fr
                if end - start >= options.minSilence {
                    let a: Double = runStart == 0 ? 0 : start + options.padding
                    let b: Double = i == n ? end : end - options.padding
                    if b - a >= options.minSilence * 0.5 {
                        ranges.append(a...b)
                    }
                }
                runStart = -1
            }
        }
        return ranges
    }

    /// 無音を除いた「残す区間」。
    static func keptRanges(duration: Double, silences: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var cursor: Double = 0
        for s in silences.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if s.lowerBound > cursor {
                result.append(cursor...s.lowerBound)
            }
            cursor = max(cursor, s.upperBound)
        }
        if cursor < duration {
            result.append(cursor...duration)
        }
        return result
    }
}

/// ラウドネス（BS.1770 の積分ラウドネスを 10ms の特徴量から近似する。Q53: 音量の自動そろえ）。
enum Loudness {
    static func integratedLUFS(_ features: AudioFeatures) -> Double? {
        var energy: [Double] = []
        if features.kWeighted.count == features.rms.count && !features.kWeighted.isEmpty {
            for v in features.kWeighted { energy.append(Double(v)) }
        } else {
            for v in features.rms { energy.append(Double(v) * Double(v)) }
        }
        let fr: Double = features.frameRate
        let block: Int = max(1, Int(fr * 0.4))
        let step: Int = max(1, Int(fr * 0.1))
        if energy.count < block { return nil }
        var prefix: [Double] = Array(repeating: 0, count: energy.count + 1)
        for i in 0..<energy.count {
            prefix[i + 1] = prefix[i] + energy[i]
        }
        var blocks: [Double] = []
        var start: Int = 0
        while start + block <= energy.count {
            blocks.append((prefix[start + block] - prefix[start]) / Double(block))
            start += step
        }
        func lufs(_ meanSquare: Double) -> Double {
            return -0.691 + 10 * log10(max(1e-12, meanSquare))
        }
        let absoluteGated: [Double] = blocks.filter { lufs($0) > -70 }
        if absoluteGated.isEmpty { return nil }
        var sum: Double = 0
        for v in absoluteGated { sum += v }
        let relativeThreshold: Double = lufs(sum / Double(absoluteGated.count)) - 10
        let gated: [Double] = absoluteGated.filter { lufs($0) > relativeThreshold }
        if gated.isEmpty { return nil }
        var total: Double = 0
        for v in gated { total += v }
        return lufs(total / Double(gated.count))
    }

    static func samplePeak(_ features: AudioFeatures) -> Double {
        var m: Float = 0
        for v in features.peak where v > m {
            m = v
        }
        return Double(m)
    }

    /// 目標のラウドネスにそろえる倍率（割れないように最大値で抑える）。
    static func gain(for features: AudioFeatures, targetLUFS: Double = -14) -> Double {
        guard let measured = integratedLUFS(features) else { return 1 }
        var gain: Double = Num.linear(fromDB: targetLUFS - measured)
        let peak: Double = samplePeak(features)
        if peak > 0 {
            gain = min(gain, 0.98 / peak)
        }
        return Num.clamp(gain, 0.1, 8)
    }
}

/// ハイライト抽出（Q45）。音の大きさと立ち上がり、映像の動き（あれば）から盛り上がりを点数にする。
enum HighlightDetector {
    struct Segment: Sendable {
        var start: Double
        var duration: Double
        var score: Double
    }

    /// motion は 1 秒ごとの映像の変化量（0〜1）。無ければ音声だけで決める。
    static func scores(_ features: AudioFeatures, window: Double, step: Double = 0.5, motion: [Double] = []) -> [Segment] {
        let fr: Double = features.frameRate
        let n: Int = features.rms.count
        let w: Int = max(1, Int(window * fr))
        let s: Int = max(1, Int(step * fr))
        if n < w { return [Segment(start: 0, duration: Double(n) / fr, score: 1)] }
        let onset: [Double] = BeatDetector.onsetStrength(features)
        var loud: [Double] = []
        loud.reserveCapacity(n)
        for v in features.rms {
            loud.append(Num.dB(fromLinear: Double(v)))
        }
        var result: [Segment] = []
        var start: Int = 0
        while start + w <= n {
            var level: Double = 0
            var activity: Double = 0
            for i in start..<(start + w) {
                level += max(-60, loud[i])
                if i < onset.count { activity += onset[i] }
            }
            level /= Double(w)
            activity /= Double(w)
            var score: Double = (level + 60) / 60 + 0.5 * activity
            if !motion.isEmpty {
                let second: Int = Int(Double(start) / fr)
                let last: Int = min(motion.count - 1, Int(Double(start + w) / fr))
                if second <= last {
                    var m: Double = 0
                    for i in second...last { m += motion[i] }
                    score += 0.8 * m / Double(last - second + 1)
                }
            }
            result.append(Segment(start: Double(start) / fr, duration: window, score: score))
            start += s
        }
        return result
    }

    /// 合計 target 秒になるまで、点数の高い区間を重ならないように選ぶ（時刻順で返す）。
    static func pick(_ segments: [Segment], target: Double) -> [Segment] {
        var chosen: [Segment] = []
        var total: Double = 0
        for seg in segments.sorted(by: { $0.score > $1.score }) {
            if total >= target { break }
            var overlaps: Bool = false
            for c in chosen where seg.start < c.start + c.duration && c.start < seg.start + seg.duration {
                overlaps = true
                break
            }
            if overlaps { continue }
            chosen.append(seg)
            total += seg.duration
        }
        chosen.sort { $0.start < $1.start }
        return chosen
    }
}
