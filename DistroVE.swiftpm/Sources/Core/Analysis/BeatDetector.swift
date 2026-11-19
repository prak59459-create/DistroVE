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

    /// オンセット強度。全体・低音・高音の帯域ごとに音量の立ち上がりを求め、それぞれ標準偏差 1 にそろえてから足す。
    /// 帯域を分けると、持続する 808 ベースに隠れたハイハットやクラップの拍も拾える。
    static func onsetStrength(_ f: AudioFeatures) -> [Double] {
        let n: Int = f.rms.count
        if n < 3 { return [] }
        var total: [Double] = Array(repeating: 0, count: n)
        let bands: [[Float]] = [f.rms, f.low, f.high]
        for band in bands where band.count == n {
            let o: [Double] = bandOnset(band, frameRate: f.frameRate)
            for i in 0..<n {
                total[i] += o[i]
            }
        }
        return normalized(total)
    }

    /// 1 つの帯域の立ち上がり（対数の差分の正の部分から、約 0.5 秒の移動平均を引いたもの）。
    static func bandOnset(_ band: [Float], frameRate: Double) -> [Double] {
        let n: Int = band.count
        let eps: Double = 1e-5
        var level: [Double] = Array(repeating: 0, count: n)
        for i in 0..<n {
            level[i] = log(eps + Double(band[i]))
        }
        var onset: [Double] = Array(repeating: 0, count: n)
        for i in 1..<n {
            onset[i] = max(0, level[i] - level[i - 1])
        }
        let window: Int = max(3, Int(frameRate * 0.5))
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
        return normalized(result)
    }

    static func normalized(_ values: [Double]) -> [Double] {
        let n: Int = values.count
        if n == 0 { return values }
        var sum: Double = 0
        var sumSq: Double = 0
        for v in values {
            sum += v
            sumSq += v * v
        }
        let mean: Double = sum / Double(n)
        let variance: Double = sumSq / Double(n) - mean * mean
        if variance <= 1e-12 { return values }
        let sd: Double = variance.squareRoot()
        var result: [Double] = values
        for i in 0..<n {
            result[i] = values[i] / sd
        }
        return result
    }

    /// 自己相関でビートの周期（フレーム数、小数あり）を推定する。
    /// シンコペーション（phonk のキックなど）の間隔に引っ張られないよう、周期の 2 倍（半小節）と 4 倍（1 小節）の
    /// 自己相関も足し合わせて評価する。120BPM 付近を少し優先する。
    static func estimatePeriod(_ onset: [Double], frameRate fr: Double, minBPM: Double, maxBPM: Double) -> Double? {
        let minLag: Int = max(2, Int((60 * fr / maxBPM).rounded(.down)))
        let maxLag: Int = Int((60 * fr / minBPM).rounded(.up))
        // テンポはふつう一定なので、長い曲は最初の 90 秒で推定する（計算量を抑える）
        let n: Int = min(onset.count, Int(fr * 90))
        if maxLag + 2 >= n { return nil }
        let maxMultiple: Int = min(4, max(1, (n - 2) / max(1, maxLag + 1)))
        let lagLimit: Int = (maxLag + 1) * maxMultiple
        var autocorrelation: [Double] = Array(repeating: 0, count: lagLimit + 1)
        onset.withUnsafeBufferPointer { o in
            for lag in minLag...lagLimit where lag < n {
                var acc: Double = 0
                var i: Int = lag
                while i < n {
                    acc += o[i] * o[i - lag]
                    i += 1
                }
                autocorrelation[lag] = acc / Double(n - lag)
            }
        }
        let preferredLag: Double = 60 * fr / 120
        var scores: [Double] = Array(repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) {
            var acc: Double = autocorrelation[lag]
            var weight: Double = 1
            var multiple: Int = 2
            while multiple <= 4 && lag * multiple <= lagLimit {
                if multiple != 3 {
                    // 整数の周期の倍数は本当の山から少しずれるので、前後 multiple/2 フレームの最大値を取る
                    let center: Int = lag * multiple
                    let spread: Int = multiple / 2
                    var best: Double = 0
                    var k: Int = max(minLag, center - spread)
                    while k <= min(lagLimit, center + spread) {
                        if autocorrelation[k] > best { best = autocorrelation[k] }
                        k += 1
                    }
                    acc += best
                    weight += 1
                }
                multiple += 1
            }
            let octaves: Double = log2(Double(lag) / preferredLag)
            let prior: Double = exp(-0.5 * (octaves / 1.0) * (octaves / 1.0))
            scores[lag] = acc / weight * prior
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
