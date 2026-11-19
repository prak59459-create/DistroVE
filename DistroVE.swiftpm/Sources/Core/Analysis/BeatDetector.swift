import Foundation

/// ビート検出の結果。
struct BeatAnalysis: Sendable {
    var bpm: Double
    /// ビートの時刻（秒、素材の先頭から）
    var beats: [Double]
    /// 小節の頭と推定したビートの番号
    var downbeatOffset: Int
    /// 0〜1 の確からしさ
    var confidence: Double

    var downbeats: [Double] {
        var result: [Double] = []
        var i: Int = downbeatOffset
        while i < beats.count {
            result.append(beats[i])
            i += 4
        }
        return result
    }
}

/// オンセット（音の立ち上がり）の強さからテンポを求め、動的計画法でビート位置を追う（Ellis 2007 の方法）。
/// 入力は 10ms ごとの特徴量なので、長い曲でも軽い。
enum BeatDetector {
    static func analyze(_ features: AudioFeatures, minBPM: Double = 60, maxBPM: Double = 200) -> BeatAnalysis? {
        let onset: [Double] = onsetStrength(features)
        let fr: Double = features.frameRate
        if onset.count < Int(fr * 3) { return nil }
        guard let period = estimatePeriod(onset, frameRate: fr, minBPM: minBPM, maxBPM: maxBPM) else { return nil }
        let frames: [Int] = track(onset, period: period)
        if frames.count < 4 { return nil }
        var beats: [Double] = []
        for f in frames {
            beats.append(Double(f) / fr)
        }
        let bpm: Double = 60 * fr / period
        let downbeat: Int = downbeatOffset(frames: frames, low: features.low)
        let confidence: Double = beatConfidence(onset, frames: frames)
        return BeatAnalysis(bpm: bpm, beats: beats, downbeatOffset: downbeat, confidence: confidence)
    }

    /// 低音と全体の音量の立ち上がりを合わせたオンセット強度（平均 0・標準偏差 1 に正規化）。
    static func onsetStrength(_ f: AudioFeatures) -> [Double] {
        let n: Int = f.rms.count
        if n < 3 { return [] }
        let eps: Double = 1e-5
        var full: [Double] = Array(repeating: 0, count: n)
        var low: [Double] = Array(repeating: 0, count: n)
        for i in 0..<n {
            full[i] = log(eps + Double(f.rms[i]))
            low[i] = log(eps + Double(i < f.low.count ? f.low[i] : 0))
        }
        var onset: [Double] = Array(repeating: 0, count: n)
        for i in 1..<n {
            let a: Double = max(0, full[i] - full[i - 1])
            let b: Double = max(0, low[i] - low[i - 1])
            onset[i] = a + 1.5 * b
        }
        // ゆっくりした音量変化を取り除く（約 0.5 秒の移動平均を引く）
        let window: Int = max(3, Int(f.frameRate * 0.5))
        var prefix: [Double] = Array(repeating: 0, count: n + 1)
        for i in 0..<n {
            prefix[i + 1] = prefix[i] + onset[i]
        }
        var result: [Double] = Array(repeating: 0, count: n)
        for i in 0..<n {
            let lo: Int = max(0, i - window / 2)
            let hi: Int = min(n, i + window / 2 + 1)
            let mean: Double = (prefix[hi] - prefix[lo]) / Double(hi - lo)
            result[i] = max(0, onset[i] - mean)
        }
        var sum: Double = 0
        var sumSq: Double = 0
        for v in result {
            sum += v
            sumSq += v * v
        }
        let mean: Double = sum / Double(n)
        let variance: Double = max(1e-12, sumSq / Double(n) - mean * mean)
        let sd: Double = variance.squareRoot()
        for i in 0..<n {
            result[i] = result[i] / sd
        }
        return result
    }

    /// 自己相関でビートの周期（フレーム数、小数あり）を推定する。120BPM 付近を少し優先する。
    static func estimatePeriod(_ onset: [Double], frameRate fr: Double, minBPM: Double, maxBPM: Double) -> Double? {
        let minLag: Int = max(2, Int((60 * fr / maxBPM).rounded(.down)))
        let maxLag: Int = Int((60 * fr / minBPM).rounded(.up))
        let n: Int = onset.count
        if maxLag + 2 >= n { return nil }
        let preferredLag: Double = 60 * fr / 120
        var scores: [Double] = Array(repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var acc: Double = 0
            var i: Int = lag
            while i < n {
                acc += onset[i] * onset[i - lag]
                i += 1
            }
            acc /= Double(n - lag)
            let octaves: Double = log2(Double(lag) / preferredLag)
            let prior: Double = exp(-0.5 * (octaves / 1.0) * (octaves / 1.0))
            scores[lag] = acc * prior
        }
        var bestLag: Int = minLag
        var best: Double = -Double.infinity
        for lag in minLag...maxLag where scores[lag] > best {
            best = scores[lag]
            bestLag = lag
        }
        if best <= 0 { return nil }
        // 放物線補間で小数点以下まで求める
        let a: Double = scores[max(minLag, bestLag - 1)]
        let b: Double = scores[bestLag]
        let c: Double = scores[min(maxLag + 1, bestLag + 1)]
        let denominator: Double = a - 2 * b + c
        var refined: Double = Double(bestLag)
        if abs(denominator) > 1e-12 {
            let shift: Double = 0.5 * (a - c) / denominator
            if abs(shift) < 1 { refined += shift }
        }
        return refined
    }

    /// 動的計画法でビート位置を決める。
    static func track(_ onset: [Double], period: Double, tightness: Double = 100) -> [Int] {
        let n: Int = onset.count
        var score: [Double] = Array(repeating: 0, count: n)
        var back: [Int] = Array(repeating: -1, count: n)
        let minBack: Int = max(1, Int((period / 2).rounded()))
        let maxBack: Int = Int((period * 2).rounded())
        for i in 0..<n {
            var best: Double = 0
            var bestIndex: Int = -1
            let lower: Int = max(0, i - maxBack)
            let upper: Int = i - minBack
            if upper >= lower {
                for j in lower...upper {
                    let ratio: Double = Double(i - j) / period
                    let penalty: Double = log(ratio)
                    let candidate: Double = score[j] - tightness * penalty * penalty
                    if bestIndex < 0 || candidate > best {
                        best = candidate
                        bestIndex = j
                    }
                }
            }
            if bestIndex >= 0 && best > 0 {
                score[i] = onset[i] + best
                back[i] = bestIndex
            } else {
                score[i] = onset[i]
            }
        }
        // 最後の 1 周期の中で一番良い点から逆にたどる
        let tailStart: Int = max(0, n - Int(period.rounded()) - 1)
        var end: Int = n - 1
        var bestTail: Double = -Double.infinity
        for i in tailStart..<n where score[i] > bestTail {
            bestTail = score[i]
            end = i
        }
        var frames: [Int] = []
        var cursor: Int = end
        while cursor >= 0 {
            frames.append(cursor)
            cursor = back[cursor]
        }
        frames.reverse()
        return trimWeakEdges(frames, onset: onset)
    }

    /// 曲の頭や終わりの無音部分に並んだ弱いビートを外す。
    static func trimWeakEdges(_ frames: [Int], onset: [Double]) -> [Int] {
        if frames.count < 8 { return frames }
        var strengths: [Double] = []
        for f in frames {
            var m: Double = 0
            let lo: Int = max(0, f - 2)
            let hi: Int = min(onset.count - 1, f + 2)
            for i in lo...hi where onset[i] > m {
                m = onset[i]
            }
            strengths.append(m)
        }
        let sorted: [Double] = strengths.sorted()
        let median: Double = sorted[sorted.count / 2]
        let threshold: Double = median * 0.15
        var first: Int = 0
        while first < frames.count - 1 && strengths[first] < threshold { first += 1 }
        var last: Int = frames.count - 1
        while last > first && strengths[last] < threshold { last -= 1 }
        return Array(frames[first...last])
    }

    /// 4 拍のうち低音が一番強い位置を小節の頭とみなす。
    static func downbeatOffset(frames: [Int], low: [Float]) -> Int {
        if frames.count < 8 || low.isEmpty { return 0 }
        var sums: [Double] = [0, 0, 0, 0]
        for (i, f) in frames.enumerated() where f < low.count {
            sums[i % 4] += Double(low[f])
        }
        var best: Int = 0
        for i in 1..<4 where sums[i] > sums[best] {
            best = i
        }
        return best
    }

    static func beatConfidence(_ onset: [Double], frames: [Int]) -> Double {
        if frames.isEmpty || onset.isEmpty { return 0 }
        var onBeat: Double = 0
        for f in frames where f < onset.count {
            onBeat += onset[f]
        }
        onBeat /= Double(frames.count)
        var total: Double = 0
        for v in onset { total += v }
        let mean: Double = total / Double(onset.count)
        return Num.clamp((onBeat - mean) / 3, 0, 1)
    }
}
