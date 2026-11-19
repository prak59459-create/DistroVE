import Foundation

/// 音声を 10 ミリ秒ごとにまとめた特徴量。波形表示・ビート検出・無音カット・音量の自動そろえに使う。
/// 生の音声を持たないので、1 時間を超える素材でもメモリを抑えられる。
struct AudioFeatures: Sendable {
    /// 1 秒あたりのフレーム数（既定 100）
    var frameRate: Double
    var sampleRate: Double
    var channels: Int
    /// 全帯域の RMS（0〜1）
    var rms: [Float]
    /// 低音（約 150Hz 以下）の RMS。キックの検出に使う
    var low: [Float]
    /// 高音（約 2.5kHz 以上）の RMS。ハイハット・スネア・クラップの検出に使う
    var high: [Float]
    /// 最大振幅（波形表示用）
    var peak: [Float]
    /// K 特性をかけた二乗平均（ラウドネス計算用。無ければ rms で代用）
    var kWeighted: [Float]

    init(frameRate: Double, sampleRate: Double, channels: Int) {
        self.frameRate = frameRate
        self.sampleRate = sampleRate
        self.channels = channels
        self.rms = []
        self.low = []
        self.high = []
        self.peak = []
        self.kWeighted = []
    }

    var frameCount: Int { return rms.count }
    var duration: Double { return Double(rms.count) / frameRate }

    func frameIndex(atSeconds seconds: Double) -> Int {
        return max(0, min(rms.count - 1, Int(seconds * frameRate)))
    }

    /// 波形表示用に、区間 [from, to) 秒を count 本の棒にまとめる（0〜1）。
    func waveform(from: Double, to: Double, count: Int) -> [Float] {
        if count <= 0 || peak.isEmpty || to <= from { return [] }
        var result: [Float] = Array(repeating: 0, count: count)
        let span: Double = (to - from) / Double(count)
        for i in 0..<count {
            let a: Int = Int((from + span * Double(i)) * frameRate)
            let b: Int = max(a + 1, Int((from + span * Double(i + 1)) * frameRate))
            var m: Float = 0
            var j: Int = max(0, a)
            let upper: Int = min(peak.count, b)
            while j < upper {
                if peak[j] > m { m = peak[j] }
                j += 1
            }
            result[i] = m
        }
        return result
    }

    // MARK: 保存用のバイナリ形式（キャッシュ）

    private static let magic: UInt32 = 0x4456_4146

    func serialized() -> Data {
        var data = Data()
        Self.append(&data, Self.magic)
        Self.append(&data, UInt32(2))
        Self.append(&data, frameRate)
        Self.append(&data, sampleRate)
        Self.append(&data, UInt32(channels))
        Self.append(&data, UInt32(rms.count))
        Self.append(&data, UInt32(high.count))
        Self.append(&data, UInt32(kWeighted.count))
        Self.appendFloats(&data, rms)
        Self.appendFloats(&data, low)
        Self.appendFloats(&data, high)
        Self.appendFloats(&data, peak)
        Self.appendFloats(&data, kWeighted)
        return data
    }

    init?(data: Data) {
        var offset: Int = 0
        guard let magic: UInt32 = Self.read(data, &offset), magic == Self.magic else { return nil }
        // 形式 1（高音なし）のキャッシュは作り直す
        guard let version: UInt32 = Self.read(data, &offset), version == 2 else { return nil }
        guard let fr: Double = Self.read(data, &offset), let sr: Double = Self.read(data, &offset) else { return nil }
        guard let ch: UInt32 = Self.read(data, &offset), let count: UInt32 = Self.read(data, &offset) else { return nil }
        guard let hCount: UInt32 = Self.read(data, &offset), let kCount: UInt32 = Self.read(data, &offset) else { return nil }
        let n: Int = Int(count)
        guard let r = Self.readFloats(data, &offset, n), let l = Self.readFloats(data, &offset, n) else { return nil }
        guard let h = Self.readFloats(data, &offset, Int(hCount)) else { return nil }
        guard let p = Self.readFloats(data, &offset, n), let k = Self.readFloats(data, &offset, Int(kCount)) else { return nil }
        frameRate = fr
        sampleRate = sr
        channels = Int(ch)
        rms = r
        low = l
        high = h
        peak = p
        kWeighted = k
    }

    private static func append<T>(_ data: inout Data, _ value: T) {
        var v: T = value
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendFloats(_ data: inout Data, _ values: [Float]) {
        values.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }
    }

    private static func read<T>(_ data: Data, _ offset: inout Int) -> T? {
        let size: Int = MemoryLayout<T>.size
        if offset + size > data.count { return nil }
        let start: Int = data.startIndex + offset
        let slice: Data = data.subdata(in: start..<(start + size))
        offset += size
        return slice.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    private static func readFloats(_ data: Data, _ offset: inout Int, _ count: Int) -> [Float]? {
        let size: Int = MemoryLayout<Float>.size * count
        if offset + size > data.count { return nil }
        var result: [Float] = Array(repeating: 0, count: count)
        let start: Int = data.startIndex + offset
        result.withUnsafeMutableBytes { target in
            _ = data.copyBytes(to: target, from: start..<(start + size))
        }
        offset += size
        return result
    }
}

/// 生の音声（モノラル）から特徴量を作る。Linux のテストと、Apple 以外の環境での予備に使う。
/// 端末では Engine 側が Accelerate を使って同じものを速く作る。
enum AudioFeatureExtractor {
    static func extract(samples: [Float], sampleRate: Double, frameRate: Double = 100) -> AudioFeatures {
        let hop: Int = max(1, Int(sampleRate / frameRate))
        // 割り切れないサンプリング周波数（11025Hz など）でも時刻がずれないよう、実際のフレームレートを記録する
        var features = AudioFeatures(frameRate: sampleRate / Double(hop), sampleRate: sampleRate, channels: 1)
        let lowCoefficient: Float = Float(1 - exp(-2 * Double.pi * 150 / sampleRate))
        let highCoefficient: Float = Float(1 - exp(-2 * Double.pi * 2500 / sampleRate))
        var lowState: Float = 0
        var highState: Float = 0
        var kFilter = KWeightingFilter(sampleRate: sampleRate)
        var index: Int = 0
        while index + hop <= samples.count {
            var sum: Double = 0
            var lowSum: Double = 0
            var highSum: Double = 0
            var kSum: Double = 0
            var maxValue: Float = 0
            for i in index..<(index + hop) {
                let s: Float = samples[i]
                sum += Double(s * s)
                lowState += lowCoefficient * (s - lowState)
                lowSum += Double(lowState * lowState)
                highState += highCoefficient * (s - highState)
                let h: Float = s - highState
                highSum += Double(h * h)
                let k: Double = kFilter.process(Double(s))
                kSum += k * k
                let a: Float = abs(s)
                if a > maxValue { maxValue = a }
            }
            features.rms.append(Float((sum / Double(hop)).squareRoot()))
            features.low.append(Float((lowSum / Double(hop)).squareRoot()))
            features.high.append(Float((highSum / Double(hop)).squareRoot()))
            features.kWeighted.append(Float(kSum / Double(hop)))
            features.peak.append(maxValue)
            index += hop
        }
        return features
    }
}

/// ITU-R BS.1770 の K 特性フィルター（任意のサンプリング周波数で係数を計算する）。
struct KWeightingFilter {
    struct Biquad {
        var b0: Double
        var b1: Double
        var b2: Double
        var a1: Double
        var a2: Double
        var z1: Double = 0
        var z2: Double = 0

        mutating func process(_ x: Double) -> Double {
            let y: Double = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    var shelf: Biquad
    var highPass: Biquad

    init(sampleRate fs: Double) {
        shelf = KWeightingFilter.highShelf(fs: fs)
        highPass = KWeightingFilter.highPass(fs: fs)
    }

    mutating func process(_ x: Double) -> Double {
        return highPass.process(shelf.process(x))
    }

    /// 係数（b0, b1, b2, a1, a2）を 2 段分。vDSP の biquad にもそのまま渡せる。
    static func coefficients(sampleRate fs: Double) -> [Double] {
        let s: Biquad = highShelf(fs: fs)
        let h: Biquad = highPass(fs: fs)
        return [s.b0, s.b1, s.b2, s.a1, s.a2, h.b0, h.b1, h.b2, h.a1, h.a2]
    }

    static func highShelf(fs: Double) -> Biquad {
        let gain: Double = 3.99984385397
        let q: Double = 0.7071752369554193
        let fc: Double = 1681.974450955533
        let a: Double = pow(10, gain / 40)
        let w0: Double = 2 * Double.pi * fc / fs
        let alpha: Double = sin(w0) / (2 * q)
        let cosw: Double = cos(w0)
        let sqrtA: Double = a.squareRoot()
        let b0: Double = a * ((a + 1) + (a - 1) * cosw + 2 * sqrtA * alpha)
        let b1: Double = -2 * a * ((a - 1) + (a + 1) * cosw)
        let b2: Double = a * ((a + 1) + (a - 1) * cosw - 2 * sqrtA * alpha)
        let a0: Double = (a + 1) - (a - 1) * cosw + 2 * sqrtA * alpha
        let a1: Double = 2 * ((a - 1) - (a + 1) * cosw)
        let a2: Double = (a + 1) - (a - 1) * cosw - 2 * sqrtA * alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func highPass(fs: Double) -> Biquad {
        let q: Double = 0.5003270373253953
        let fc: Double = 38.13547087613982
        let w0: Double = 2 * Double.pi * fc / fs
        let alpha: Double = sin(w0) / (2 * q)
        let cosw: Double = cos(w0)
        let b0: Double = (1 + cosw) / 2
        let b1: Double = -(1 + cosw)
        let b2: Double = (1 + cosw) / 2
        let a0: Double = 1 + alpha
        let a1: Double = -2 * cosw
        let a2: Double = 1 - alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}
