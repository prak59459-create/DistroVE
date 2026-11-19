import Foundation

enum SoundCategory: String, Codable, Sendable {
    case bgm
    case sfx
}

/// 内蔵の BGM・効果音（Q54）。音源ファイルは同梱せず、初回に端末内で合成して保存する。
/// 合成した音源なので著作権の心配がなく、アプリのサイズも増えない。
struct SoundDefinition: Identifiable, Sendable {
    let id: String
    let name: String
    let category: SoundCategory
    let bpm: Double?
    let summary: String
}

enum SoundLibrary {
    static let sampleRate: Double = 22_050

    static let all: [SoundDefinition] = [
        SoundDefinition(id: "bgm.phonk", name: "Drift Phonk", category: .bgm, bpm: 130, summary: "カウベルと 808 の phonk（130BPM）"),
        SoundDefinition(id: "bgm.upbeat", name: "Upbeat Pop", category: .bgm, bpm: 120, summary: "明るい四つ打ち（120BPM）"),
        SoundDefinition(id: "bgm.lofi", name: "Lo-Fi Chill", category: .bgm, bpm: 85, summary: "落ち着いた Lo-Fi（85BPM）"),
        SoundDefinition(id: "bgm.cinematic", name: "Cinematic Pad", category: .bgm, bpm: 70, summary: "映画風のパッドと重い打撃（70BPM）"),
        SoundDefinition(id: "bgm.drums", name: "Drum Groove", category: .bgm, bpm: 100, summary: "ドラムだけのループ（100BPM）"),
        SoundDefinition(id: "sfx.whoosh", name: "シュッ", category: .sfx, bpm: nil, summary: "場面転換の風切り音"),
        SoundDefinition(id: "sfx.impact", name: "ドン", category: .sfx, bpm: nil, summary: "重い衝撃音"),
        SoundDefinition(id: "sfx.riser", name: "ライザー", category: .sfx, bpm: nil, summary: "盛り上がりの前に"),
        SoundDefinition(id: "sfx.ding", name: "チーン", category: .sfx, bpm: nil, summary: "正解・お知らせ"),
        SoundDefinition(id: "sfx.pop", name: "ポン", category: .sfx, bpm: nil, summary: "テキストの登場に"),
        SoundDefinition(id: "sfx.click", name: "カチッ", category: .sfx, bpm: nil, summary: "クリック音"),
        SoundDefinition(id: "sfx.glitch", name: "グリッチ", category: .sfx, bpm: nil, summary: "電子的なノイズ"),
        SoundDefinition(id: "sfx.shutter", name: "シャッター", category: .sfx, bpm: nil, summary: "カメラのシャッター"),
        SoundDefinition(id: "sfx.cowbell", name: "カウベル", category: .sfx, bpm: nil, summary: "phonk のカウベル 1 打"),
        SoundDefinition(id: "sfx.bass", name: "808 ベース", category: .sfx, bpm: nil, summary: "低いベースの 1 打")
    ]

    static func definition(_ id: String) -> SoundDefinition? {
        return all.first { $0.id == id }
    }

    /// 合成した音（モノラル、-1〜1）。
    static func render(_ id: String) -> [Float]? {
        var synth = Synth(sampleRate: sampleRate)
        switch id {
        case "bgm.phonk": synth.phonk()
        case "bgm.upbeat": synth.upbeat()
        case "bgm.lofi": synth.lofi()
        case "bgm.cinematic": synth.cinematic()
        case "bgm.drums": synth.drums()
        case "sfx.whoosh": synth.whoosh()
        case "sfx.impact": synth.impact()
        case "sfx.riser": synth.riser()
        case "sfx.ding": synth.ding()
        case "sfx.pop": synth.pop()
        case "sfx.click": synth.click()
        case "sfx.glitch": synth.glitch()
        case "sfx.shutter": synth.shutter()
        case "sfx.cowbell": synth.ensure(0.5); synth.cowbell(at: 0, frequency: 800, gain: 0.8)
        case "sfx.bass": synth.ensure(1.3); synth.bass808(at: 0, frequency: 41.2, length: 1.2, gain: 0.9)
        default: return nil
        }
        synth.normalize(peak: 0.89)
        return synth.samples
    }

    /// 16bit PCM の WAV にする。
    static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        let rate: UInt32 = UInt32(sampleRate)
        let dataSize: UInt32 = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLE(&data, UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLE(&data, UInt32(16))
        appendLE(&data, UInt16(1))
        appendLE(&data, UInt16(1))
        appendLE(&data, rate)
        appendLE(&data, rate * 2)
        appendLE(&data, UInt16(2))
        appendLE(&data, UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        appendLE(&data, dataSize)
        var pcm: [Int16] = []
        pcm.reserveCapacity(samples.count)
        for s in samples {
            let clamped: Float = max(-1, min(1, s))
            pcm.append(Int16(clamped * 32_767))
        }
        pcm.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UInt8.self) { bytes in
                data.append(bytes.baseAddress!, count: bytes.count)
            }
        }
        return data
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        var v: UInt32 = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendLE(_ data: inout Data, _ value: UInt16) {
        var v: UInt16 = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

/// とても小さなシンセサイザー。音ごとに必要な長さだけ足し込むので、デバッグビルドでも数百ミリ秒で終わる。
struct Synth {
    let sampleRate: Double
    var samples: [Float] = []
    private var noiseState: UInt32 = 22_222

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    mutating func ensure(_ seconds: Double) {
        let count: Int = Int(seconds * sampleRate)
        if samples.count < count {
            samples.append(contentsOf: Array(repeating: 0, count: count - samples.count))
        }
    }

    mutating func noise() -> Double {
        noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
        return Double(noiseState >> 8) / Double(1 << 24) * 2 - 1
    }

    /// time 秒から length 秒、voice(t) を足し込む。
    mutating func add(at time: Double, length: Double, gain: Double, _ voice: (inout Synth, Double) -> Double) {
        let start: Int = Int(time * sampleRate)
        let count: Int = Int(length * sampleRate)
        ensure(time + length + 0.01)
        if start < 0 { return }
        let dt: Double = 1 / sampleRate
        var values: [Float] = Array(repeating: 0, count: count)
        for i in 0..<count {
            values[i] = Float(voice(&self, Double(i) * dt) * gain)
        }
        let upper: Int = min(samples.count, start + count)
        var j: Int = start
        while j < upper {
            samples[j] += values[j - start]
            j += 1
        }
    }

    mutating func normalize(peak: Float) {
        var m: Float = 0
        for s in samples where abs(s) > m {
            m = abs(s)
        }
        if m <= 0 { return }
        let k: Float = peak / m
        for i in samples.indices {
            let v: Float = samples[i] * k
            samples[i] = v / (1 + abs(v) * 0.15) * 1.15
        }
    }

    // MARK: 音色

    mutating func kick(at t0: Double, gain: Double) {
        add(at: t0, length: 0.45, gain: gain) { s, t in
            let phase: Double = 2 * Double.pi * (45 * t + 110.0 / 30.0 * (1 - exp(-30 * t)))
            return sin(phase) * exp(-9 * t) + s.noise() * exp(-300 * t) * 0.25
        }
    }

    mutating func bass808(at t0: Double, frequency: Double, length: Double, gain: Double) {
        add(at: t0, length: length, gain: gain) { _, t in
            let env: Double = exp(-2.2 * t) * (1 - exp(-200 * t))
            let release: Double = t > length - 0.05 ? max(0, (length - t) / 0.05) : 1
            return tanh(1.8 * sin(2 * Double.pi * frequency * t)) * env * release
        }
    }

    mutating func snare(at t0: Double, gain: Double) {
        add(at: t0, length: 0.3, gain: gain) { s, t in
            return s.noise() * exp(-18 * t) * 0.7 + sin(2 * Double.pi * 190 * t) * exp(-25 * t) * 0.5
        }
    }

    mutating func clap(at t0: Double, gain: Double) {
        add(at: t0, length: 0.35, gain: gain) { s, t in
            var env: Double = exp(-12 * t) * 0.6 + exp(-70 * t) * 0.5
            if t >= 0.011 { env += exp(-70 * (t - 0.011)) * 0.5 }
            if t >= 0.023 { env += exp(-70 * (t - 0.023)) * 0.5 }
            return s.noise() * env
        }
    }

    mutating func hat(at t0: Double, gain: Double, open: Bool = false) {
        let decay: Double = open ? 14 : 70
        add(at: t0, length: open ? 0.3 : 0.08, gain: gain) { s, t in
            let a: Double = s.noise()
            let b: Double = s.noise()
            return (a - b) * 0.5 * exp(-decay * t)
        }
    }

    mutating func cowbell(at t0: Double, frequency: Double, gain: Double) {
        add(at: t0, length: 0.42, gain: gain) { _, t in
            let x1: Double = 2 * Double.pi * frequency * t
            let x2: Double = 2 * Double.pi * frequency * 1.48 * t
            let tone: Double = sin(x1) + sin(3 * x1) / 3 + 0.7 * (sin(x2) + sin(3 * x2) / 3)
            return tone * 0.35 * exp(-7 * t) * (1 - exp(-400 * t))
        }
    }

    mutating func keys(at t0: Double, frequency: Double, length: Double, gain: Double) {
        add(at: t0, length: length, gain: gain) { _, t in
            let x: Double = 2 * Double.pi * frequency * t
            let release: Double = t > length - 0.1 ? max(0, (length - t) / 0.1) : 1
            return (sin(x) * exp(-2.5 * t) + 0.3 * sin(2 * x) * exp(-5 * t)) * release * (1 - exp(-300 * t))
        }
    }

    mutating func pad(at t0: Double, frequencies: [Double], length: Double, gain: Double) {
        add(at: t0, length: length, gain: gain) { _, t in
            var v: Double = 0
            for f in frequencies {
                v += sin(2 * Double.pi * f * t) + 0.5 * sin(2 * Double.pi * f * 1.003 * t)
            }
            let attack: Double = min(1, t / 0.4)
            let release: Double = t > length - 0.6 ? max(0, (length - t) / 0.6) : 1
            return v / Double(max(1, frequencies.count)) * attack * release * 0.5
        }
    }

    mutating func boom(at t0: Double, gain: Double) {
        add(at: t0, length: 2.2, gain: gain) { s, t in
            let phase: Double = 2 * Double.pi * (32 * t + 60.0 / 8.0 * (1 - exp(-8 * t)))
            return sin(phase) * exp(-2.2 * t) + s.noise() * exp(-10 * t) * 0.3
        }
    }

    mutating func crackle(length: Double, gain: Double) {
        add(at: 0, length: length, gain: gain) { s, _ in
            let n: Double = s.noise()
            return abs(n) > 0.9993 ? n : n * 0.01
        }
    }

    static func note(_ semitonesFromA4: Double) -> Double {
        return 440 * pow(2, semitonesFromA4 / 12)
    }

    // MARK: BGM

    mutating func phonk() {
        let beat: Double = 60.0 / 130.0
        let bars: Int = 16
        ensure(Double(bars * 4) * beat + 1)
        let bassNotes: [Double] = [41.2, 41.2, 49.0, 36.7]
        let melody: [Int] = [7, -1, 7, 10, -1, 7, 5, -1, 7, -1, 14, 12, 10, -1, 7, -1]
        for bar in 0..<bars {
            let t: Double = Double(bar * 4) * beat
            let drums: Bool = bar >= 1
            if drums {
                kick(at: t, gain: 0.9)
                kick(at: t + 1.75 * beat, gain: 0.7)
                kick(at: t + 2.5 * beat, gain: 0.85)
                clap(at: t + beat, gain: 0.5)
                clap(at: t + 3 * beat, gain: 0.5)
                for h in 0..<8 {
                    hat(at: t + Double(h) * beat / 2, gain: h % 2 == 0 ? 0.25 : 0.15)
                }
                if bar % 4 == 3 {
                    for r in 0..<6 { hat(at: t + 3 * beat + Double(r) * beat / 6, gain: 0.18) }
                }
                let root: Double = bassNotes[bar % 4]
                bass808(at: t, frequency: root, length: 1.5 * beat, gain: 0.85)
                bass808(at: t + 2.5 * beat, frequency: root, length: 1.2 * beat, gain: 0.75)
            }
            for (i, step) in melody.enumerated() where step >= 0 {
                let f: Double = Synth.note(Double(step) - 5 + 12)
                cowbell(at: t + Double(i) * beat / 4, frequency: f, gain: 0.32)
            }
        }
    }

    mutating func upbeat() {
        let beat: Double = 0.5
        let bars: Int = 16
        ensure(Double(bars * 4) * beat + 1)
        let roots: [Double] = [65.4, 98.0, 110.0, 87.3]
        let chords: [[Double]] = [[261.6, 329.6, 392.0], [196.0, 246.9, 293.7], [220.0, 261.6, 329.6], [174.6, 220.0, 261.6]]
        for bar in 0..<bars {
            let t: Double = Double(bar * 4) * beat
            for b in 0..<4 {
                kick(at: t + Double(b) * beat, gain: 0.8)
                hat(at: t + (Double(b) + 0.5) * beat, gain: 0.22, open: true)
                bass808(at: t + (Double(b) + 0.5) * beat, frequency: roots[bar % 4], length: 0.4 * beat, gain: 0.45)
            }
            clap(at: t + beat, gain: 0.45)
            clap(at: t + 3 * beat, gain: 0.45)
            let chord: [Double] = chords[bar % 4]
            for b in [0.0, 1.5, 2.5] {
                for f in chord { keys(at: t + b * beat, frequency: f, length: 0.45 * beat, gain: 0.16) }
            }
        }
    }

    mutating func lofi() {
        let beat: Double = 60.0 / 85.0
        let bars: Int = 10
        let total: Double = Double(bars * 4) * beat + 1
        ensure(total)
        let chords: [[Double]] = [[174.6, 220.0, 261.6, 329.6], [164.8, 196.0, 246.9, 293.7], [146.8, 174.6, 220.0, 261.6], [130.8, 164.8, 196.0, 246.9]]
        for bar in 0..<bars {
            let t: Double = Double(bar * 4) * beat
            kick(at: t, gain: 0.55)
            kick(at: t + 2.75 * beat, gain: 0.45)
            snare(at: t + beat, gain: 0.3)
            snare(at: t + 3 * beat, gain: 0.3)
            for h in 0..<8 {
                let swing: Double = h % 2 == 1 ? 0.08 * beat : 0
                hat(at: t + Double(h) * beat / 2 + swing, gain: 0.1)
            }
            let chord: [Double] = chords[bar % 4]
            for f in chord {
                keys(at: t, frequency: f, length: 2.2 * beat, gain: 0.14)
                keys(at: t + 2.5 * beat, frequency: f, length: 1.4 * beat, gain: 0.1)
            }
        }
        crackle(length: total - 0.5, gain: 0.5)
    }

    mutating func cinematic() {
        let beat: Double = 60.0 / 70.0
        let bars: Int = 8
        ensure(Double(bars * 4) * beat + 3)
        let chords: [[Double]] = [[110.0, 220.0, 261.6, 329.6], [87.3, 174.6, 220.0, 261.6], [130.8, 196.0, 261.6, 329.6], [98.0, 196.0, 246.9, 293.7]]
        for bar in stride(from: 0, to: bars, by: 2) {
            let t: Double = Double(bar * 4) * beat
            pad(at: t, frequencies: chords[(bar / 2) % 4], length: 8 * beat + 0.6, gain: 0.5)
            boom(at: t, gain: 0.8)
            boom(at: t + 6 * beat, gain: 0.45)
        }
    }

    mutating func drums() {
        let beat: Double = 0.6
        let bars: Int = 12
        ensure(Double(bars * 4) * beat + 1)
        for bar in 0..<bars {
            let t: Double = Double(bar * 4) * beat
            kick(at: t, gain: 0.9)
            kick(at: t + 2 * beat, gain: 0.8)
            kick(at: t + 2.5 * beat, gain: 0.6)
            snare(at: t + beat, gain: 0.6)
            snare(at: t + 3 * beat, gain: 0.6)
            for h in 0..<8 {
                hat(at: t + Double(h) * beat / 2, gain: h % 2 == 0 ? 0.28 : 0.16)
            }
            if bar % 4 == 0 { hat(at: t, gain: 0.35, open: true) }
        }
    }

    // MARK: 効果音

    mutating func whoosh() {
        ensure(0.9)
        var low: Double = 0
        add(at: 0, length: 0.85, gain: 0.9) { s, t in
            let p: Double = t / 0.85
            let cutoff: Double = 0.02 + 0.25 * sin(Double.pi * p)
            low += cutoff * (s.noise() - low)
            return low * sin(Double.pi * p) * 3
        }
    }

    mutating func impact() {
        ensure(2.3)
        boom(at: 0, gain: 1)
        add(at: 0, length: 0.4, gain: 0.5) { s, t in s.noise() * exp(-15 * t) }
    }

    mutating func riser() {
        ensure(2.1)
        add(at: 0, length: 2, gain: 0.6) { s, t in
            let p: Double = t / 2
            let phase: Double = 2 * Double.pi * (200 * t + 250 * t * t)
            return (sin(phase) * 0.6 + s.noise() * 0.4 * p) * p
        }
    }

    mutating func ding() {
        ensure(1.1)
        add(at: 0, length: 1.0, gain: 0.6) { _, t in
            let f: Double = 880
            return sin(2 * Double.pi * f * t) * exp(-4 * t) + 0.4 * sin(2 * Double.pi * f * 2.76 * t) * exp(-7 * t)
                + 0.2 * sin(2 * Double.pi * f * 5.4 * t) * exp(-10 * t)
        }
    }

    mutating func pop() {
        ensure(0.25)
        add(at: 0, length: 0.18, gain: 0.8) { _, t in
            let phase: Double = 2 * Double.pi * (900 * t - 1900 * t * t)
            return sin(phase) * exp(-22 * t)
        }
    }

    mutating func click() {
        ensure(0.1)
        add(at: 0, length: 0.06, gain: 0.8) { s, t in s.noise() * exp(-160 * t) + sin(2 * Double.pi * 2000 * t) * exp(-120 * t) }
    }

    mutating func glitch() {
        ensure(0.65)
        for i in 0..<8 {
            let start: Double = Double(i) * 0.075
            let f: Double = 200 + Double((i * 37) % 9) * 180
            add(at: start, length: 0.06, gain: 0.5) { s, t in
                let square: Double = sin(2 * Double.pi * f * t) > 0 ? 1 : -1
                let crushed: Double = (s.noise() * 4).rounded() / 4
                return (square * 0.5 + crushed * 0.5) * (t < 0.055 ? 1 : 0)
            }
        }
    }

    mutating func shutter() {
        ensure(0.3)
        add(at: 0, length: 0.05, gain: 0.8) { s, t in s.noise() * exp(-90 * t) }
        add(at: 0.11, length: 0.08, gain: 0.7) { s, t in s.noise() * exp(-60 * t) }
    }
}
