import Foundation

/// 2 の累乗の長さの FFT（複素数・その場で計算）。
enum RadixFFT {
    /// real・imag を書き換える。inverse なら逆変換（1/n も掛ける）。
    static func transform(_ real: inout [Float], _ imag: inout [Float], inverse: Bool) {
        let n: Int = real.count
        if n <= 1 { return }
        var j: Int = 0
        for i in 1..<n {
            var bit: Int = n >> 1
            while j & bit != 0 {
                j ^= bit
                bit >>= 1
            }
            j |= bit
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
        }
        var length: Int = 2
        let sign: Float = inverse ? 1 : -1
        while length <= n {
            let angle: Float = sign * 2 * Float.pi / Float(length)
            let stepRe: Float = cos(angle)
            let stepIm: Float = sin(angle)
            var start: Int = 0
            while start < n {
                var wRe: Float = 1
                var wIm: Float = 0
                let half: Int = length / 2
                for k in 0..<half {
                    let a: Int = start + k
                    let b: Int = a + half
                    let tRe: Float = real[b] * wRe - imag[b] * wIm
                    let tIm: Float = real[b] * wIm + imag[b] * wRe
                    real[b] = real[a] - tRe
                    imag[b] = imag[a] - tIm
                    real[a] += tRe
                    imag[a] += tIm
                    let nextRe: Float = wRe * stepRe - wIm * stepIm
                    wIm = wRe * stepIm + wIm * stepRe
                    wRe = nextRe
                }
                start += length
            }
            length <<= 1
        }
        if inverse {
            let scale: Float = 1 / Float(n)
            for i in 0..<n {
                real[i] *= scale
                imag[i] *= scale
            }
        }
    }

    static func hann(_ n: Int) -> [Float] {
        var window: [Float] = []
        window.reserveCapacity(n)
        for i in 0..<n {
            window.append(0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(n)))
        }
        return window
    }
}

/// スペクトル減算によるノイズ除去（Q53）。いちばん静かな区間（全体の 15%）からノイズの形を学び、
/// 各周波数からその分を引く。急に音が出入りする「ミュージカルノイズ」を抑えるため、効き方を時間でならす。
enum SpectralDenoiser {
    static let size: Int = 1024
    static let hop: Int = 512

    /// samples は 1 チャンネル。strength は 0〜1。
    static func process(_ samples: [Float], strength: Double) -> [Float] {
        let n: Int = size
        if samples.count < n * 2 || strength <= 0.001 { return samples }
        let window: [Float] = RadixFFT.hann(n)
        let frames: Int = (samples.count - n) / hop + 1
        // 1. どの区間が静かかを調べ、静かな区間の平均の大きさをノイズとする
        var energies: [Float] = []
        energies.reserveCapacity(frames)
        for f in 0..<frames {
            var e: Float = 0
            for i in 0..<n {
                let v: Float = samples[f * hop + i]
                e += v * v
            }
            energies.append(e)
        }
        let threshold: Float = energies.sorted()[max(0, frames * 15 / 100)]
        var noise: [Float] = Array(repeating: 0, count: n / 2 + 1)
        var counted: Int = 0
        for f in 0..<frames where energies[f] <= threshold {
            let magnitudes: [Float] = SpectralDenoiser.magnitudes(samples, at: f * hop, window: window)
            for k in 0..<noise.count {
                noise[k] += magnitudes[k]
            }
            counted += 1
        }
        if counted == 0 { return samples }
        for k in 0..<noise.count {
            noise[k] /= Float(counted)
        }
        // 2. 区間ごとに、ノイズの分を引いた大きさに縮めて重ね合わせる（Hann の 50% 重ねで元に戻る）
        let over: Float = 1 + Float(strength) * 1.5
        let floor: Float = max(0.03, 0.25 - Float(strength) * 0.2)
        var output: [Float] = Array(repeating: 0, count: samples.count)
        var previous: [Float] = Array(repeating: 1, count: noise.count)
        var real: [Float] = Array(repeating: 0, count: n)
        var imag: [Float] = Array(repeating: 0, count: n)
        for f in 0..<frames {
            let base: Int = f * hop
            for i in 0..<n {
                real[i] = samples[base + i] * window[i]
                imag[i] = 0
            }
            RadixFFT.transform(&real, &imag, inverse: false)
            for k in 0...(n / 2) {
                let magnitude: Float = (real[k] * real[k] + imag[k] * imag[k]).squareRoot()
                let raw: Float = magnitude > 1e-9 ? max(floor, 1 - over * noise[k] / magnitude) : floor
                let gain: Float = 0.6 * raw + 0.4 * previous[k]
                previous[k] = gain
                real[k] *= gain
                imag[k] *= gain
                if k > 0 && k < n / 2 {
                    real[n - k] *= gain
                    imag[n - k] *= gain
                }
            }
            RadixFFT.transform(&real, &imag, inverse: true)
            for i in 0..<n {
                output[base + i] += real[i]
            }
        }
        // 最初と最後の半区間は重なりが足りないので元の音を使う
        for i in 0..<hop {
            output[i] = samples[i]
        }
        let tail: Int = (frames - 1) * hop + n
        for i in tail..<samples.count {
            output[i] = samples[i]
        }
        return output
    }

    static func magnitudes(_ samples: [Float], at start: Int, window: [Float]) -> [Float] {
        let n: Int = window.count
        var real: [Float] = Array(repeating: 0, count: n)
        var imag: [Float] = Array(repeating: 0, count: n)
        for i in 0..<n {
            real[i] = samples[start + i] * window[i]
        }
        RadixFFT.transform(&real, &imag, inverse: false)
        var result: [Float] = []
        result.reserveCapacity(n / 2 + 1)
        for k in 0...(n / 2) {
            result.append((real[k] * real[k] + imag[k] * imag[k]).squareRoot())
        }
        return result
    }
}

/// 話者の自動判別（Q57）。字幕 1 つずつの声の特徴（高さとメル帯域の強さ）を求め、k-means で分ける。
enum SpeakerClustering {
    static let bands: Int = 16

    /// 声の特徴（16kHz・1 チャンネル）。[対数の声の高さ, 帯域 1…16 の対数の強さ（平均を引いたもの）]
    /// 長い区間は真ん中の maxSeconds 秒だけを見る。声の高さ（重い計算）は 2 つおきの区切りで求める。
    static func features(_ samples: [Float], sampleRate: Double, maxSeconds: Double = 4) -> [Double]? {
        let n: Int = 512
        if samples.count < n { return nil }
        let limit: Int = max(n, Int(sampleRate * maxSeconds))
        var start: Int = 0
        var last: Int = samples.count
        if samples.count > limit {
            start = (samples.count - limit) / 2
            last = start + limit
        }
        let window: [Float] = RadixFFT.hann(n)
        var sums: [Double] = Array(repeating: 0, count: bands)
        var frames: Int = 0
        var pitches: [Double] = []
        var step: Int = 0
        while start + n <= last {
            let magnitudes: [Float] = SpectralDenoiser.magnitudes(samples, at: start, window: window)
            let energies: [Double] = SpeakerClustering.melEnergies(magnitudes, sampleRate: sampleRate, size: n)
            let loud: Double = energies.reduce(0, +)
            if loud > 1e-6 {
                for b in 0..<bands {
                    sums[b] += log(energies[b] + 1e-8)
                }
                frames += 1
                if step % 2 == 0, let pitch = SpeakerClustering.pitch(samples, at: start, length: n, sampleRate: sampleRate) { pitches.append(pitch) }
            }
            step += 1
            start += n / 2
        }
        if frames == 0 { return nil }
        var spectrum: [Double] = sums.map { $0 / Double(frames) }
        let mean: Double = spectrum.reduce(0, +) / Double(bands)
        spectrum = spectrum.map { $0 - mean }
        let sortedPitch: [Double] = pitches.sorted()
        let median: Double = sortedPitch.isEmpty ? 150 : sortedPitch[sortedPitch.count / 2]
        // 声の高さは強く効くので、ほかの帯域と同じくらいの重みにそろえる
        return [log2(median / 100) * 4] + spectrum
    }

    /// 三角形のメル帯域（80Hz〜7.6kHz）の強さ。
    static func melEnergies(_ magnitudes: [Float], sampleRate: Double, size: Int) -> [Double] {
        func mel(_ f: Double) -> Double { return 2595 * log10(1 + f / 700) }
        func hertz(_ m: Double) -> Double { return 700 * (pow(10, m / 2595) - 1) }
        let low: Double = mel(80)
        let high: Double = mel(min(7600, sampleRate / 2))
        var edges: [Double] = []
        for i in 0...(bands + 1) {
            edges.append(hertz(low + (high - low) * Double(i) / Double(bands + 1)))
        }
        let binHz: Double = sampleRate / Double(size)
        var result: [Double] = Array(repeating: 0, count: bands)
        for b in 0..<bands {
            let left: Double = edges[b]
            let center: Double = edges[b + 1]
            let right: Double = edges[b + 2]
            var k: Int = max(1, Int(left / binHz))
            while Double(k) * binHz < right && k < magnitudes.count {
                let f: Double = Double(k) * binHz
                let weight: Double = f < center ? (f - left) / max(1e-6, center - left) : (right - f) / max(1e-6, right - center)
                let m: Double = Double(magnitudes[k])
                result[b] += max(0, weight) * m * m
                k += 1
            }
        }
        return result
    }

    /// 自己相関による声の高さ（70〜400Hz）。はっきりしなければ nil。
    static func pitch(_ samples: [Float], at start: Int, length: Int, sampleRate: Double) -> Double? {
        let minLag: Int = Int(sampleRate / 400)
        let maxLag: Int = min(length - 1, Int(sampleRate / 70))
        var energy: Float = 0
        for i in 0..<length {
            energy += samples[start + i] * samples[start + i]
        }
        if energy < 1e-6 || minLag >= maxLag { return nil }
        var bestLag: Int = 0
        var best: Float = 0
        for lag in minLag...maxLag {
            var sum: Float = 0
            for i in 0..<(length - lag) {
                sum += samples[start + i] * samples[start + i + lag]
            }
            if sum > best {
                best = sum
                bestLag = lag
            }
        }
        if bestLag == 0 || best < energy * 0.3 { return nil }
        return sampleRate / Double(bestLag)
    }

    /// 特徴を maxSpeakers 人までに分ける。speakers を指定しなければ、まとまりのよさ（シルエット）で人数を決める。
    static func assign(_ features: [[Double]], speakers fixed: Int? = nil, maxSpeakers: Int = 4) -> [Int] {
        let n: Int = features.count
        if n == 0 { return [] }
        if n == 1 { return [0] }
        let normalized: [[Double]] = SpeakerClustering.standardized(features)
        if let k = fixed {
            return SpeakerClustering.ordered(SpeakerClustering.kmeans(normalized, k: max(1, min(k, n))))
        }
        var best: [Int] = Array(repeating: 0, count: n)
        var bestScore: Double = 0.25
        for k in 2...max(2, min(maxSpeakers, n - 1)) where k < n {
            let labels: [Int] = SpeakerClustering.kmeans(normalized, k: k)
            let score: Double = SpeakerClustering.silhouette(normalized, labels)
            if score > bestScore + 0.02 {
                bestScore = score
                best = labels
            }
        }
        return SpeakerClustering.ordered(best)
    }

    /// 出てきた順に 0, 1, 2… と番号を振り直す。
    static func ordered(_ labels: [Int]) -> [Int] {
        var map: [Int: Int] = [:]
        var result: [Int] = []
        for label in labels {
            if map[label] == nil { map[label] = map.count }
            result.append(map[label] ?? 0)
        }
        return result
    }

    static func standardized(_ rows: [[Double]]) -> [[Double]] {
        guard let width = rows.first?.count else { return rows }
        var means: [Double] = Array(repeating: 0, count: width)
        var deviations: [Double] = Array(repeating: 0, count: width)
        for row in rows {
            for d in 0..<width { means[d] += row[d] / Double(rows.count) }
        }
        for row in rows {
            for d in 0..<width { deviations[d] += (row[d] - means[d]) * (row[d] - means[d]) / Double(rows.count) }
        }
        return rows.map { row in (0..<width).map { d in (row[d] - means[d]) / max(1e-6, deviations[d].squareRoot()) } }
    }

    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var sum: Double = 0
        for i in 0..<min(a.count, b.count) {
            sum += (a[i] - b[i]) * (a[i] - b[i])
        }
        return sum.squareRoot()
    }

    /// k-means（最初の中心は k-means++ と同じ考えで、遠い点から決定的に選ぶ）。
    static func kmeans(_ rows: [[Double]], k: Int, iterations: Int = 30) -> [Int] {
        var centers: [[Double]] = [rows[0]]
        while centers.count < k {
            var farthest: Int = 0
            var far: Double = -1
            for (i, row) in rows.enumerated() {
                let d: Double = centers.map { SpeakerClustering.distance($0, row) }.min() ?? 0
                if d > far {
                    far = d
                    farthest = i
                }
            }
            centers.append(rows[farthest])
        }
        var labels: [Int] = Array(repeating: 0, count: rows.count)
        for _ in 0..<iterations {
            var changed: Bool = false
            for (i, row) in rows.enumerated() {
                var bestCenter: Int = 0
                var bestDistance: Double = Double.infinity
                for (c, center) in centers.enumerated() {
                    let d: Double = SpeakerClustering.distance(center, row)
                    if d < bestDistance {
                        bestDistance = d
                        bestCenter = c
                    }
                }
                if labels[i] != bestCenter {
                    labels[i] = bestCenter
                    changed = true
                }
            }
            for c in 0..<k {
                let members: [[Double]] = rows.enumerated().filter { labels[$0.offset] == c }.map { $0.element }
                if members.isEmpty { continue }
                let width: Int = members[0].count
                centers[c] = (0..<width).map { d in members.reduce(0) { $0 + $1[d] } / Double(members.count) }
            }
            if !changed { break }
        }
        return labels
    }

    /// シルエット係数（-1〜1。大きいほどきれいに分かれている）。
    static func silhouette(_ rows: [[Double]], _ labels: [Int]) -> Double {
        let clusters: Set<Int> = Set(labels)
        if clusters.count < 2 { return 0 }
        var total: Double = 0
        for (i, row) in rows.enumerated() {
            var own: [Double] = []
            var others: [Int: [Double]] = [:]
            for (j, other) in rows.enumerated() where j != i {
                let d: Double = SpeakerClustering.distance(row, other)
                if labels[j] == labels[i] { own.append(d) } else { others[labels[j], default: []].append(d) }
            }
            let a: Double = own.isEmpty ? 0 : own.reduce(0, +) / Double(own.count)
            let b: Double = others.values.map { $0.reduce(0, +) / Double($0.count) }.min() ?? 0
            let s: Double = max(a, b) > 0 ? (b - a) / max(a, b) : 0
            total += own.isEmpty ? 0 : s
        }
        return total / Double(rows.count)
    }
}
