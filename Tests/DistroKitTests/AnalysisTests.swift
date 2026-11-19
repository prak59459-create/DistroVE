import XCTest
@testable import DistroKit

final class AnalysisTests: XCTestCase {
    let rate: Double = 11_025

    /// bpm のキック（低い音の減衰するサイン波）を並べたテスト用の音。
    func clickTrack(bpm: Double, seconds: Double, offset: Double = 0.2) -> [Float] {
        let count = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: count)
        let interval = 60 / bpm
        var t = offset
        while t < seconds {
            let start = Int(t * rate)
            for i in 0..<Int(0.12 * rate) where start + i < count {
                let x = Double(i) / rate
                samples[start + i] += Float(sin(2 * Double.pi * 70 * x) * exp(-30 * x) * 0.8)
            }
            t += interval
        }
        return samples
    }

    func testBeatDetection120() throws {
        let samples = clickTrack(bpm: 120, seconds: 20)
        let features = AudioFeatureExtractor.extract(samples: samples, sampleRate: rate)
        XCTAssertEqual(features.duration, 20, accuracy: 0.02)
        let result = try XCTUnwrap(BeatDetector.analyze(features))
        XCTAssertEqual(result.bpm, 120, accuracy: 2.5)
        XCTAssertGreaterThan(result.beats.count, 30)
        var intervals: [Double] = []
        for i in 1..<result.beats.count { intervals.append(result.beats[i] - result.beats[i - 1]) }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        XCTAssertEqual(mean, 0.5, accuracy: 0.02)
        // ビートはキックの位置（0.2 + 0.5n 秒）の近くにある
        for beat in result.beats.prefix(10) {
            let phase = (beat - 0.2).truncatingRemainder(dividingBy: 0.5)
            XCTAssertTrue(phase < 0.05 || phase > 0.45, "beat at \(beat)")
        }
    }

    func testBeatDetectionPhonkTempo() throws {
        let samples = clickTrack(bpm: 140, seconds: 20)
        let features = AudioFeatureExtractor.extract(samples: samples, sampleRate: rate)
        let result = try XCTUnwrap(BeatDetector.analyze(features))
        XCTAssertEqual(result.bpm, 140, accuracy: 3)
    }

    func testSilenceDetection() {
        var samples: [Float] = []
        for i in 0..<Int(2 * rate) { samples.append(Float(sin(Double(i) * 0.3) * 0.5)) }
        samples.append(contentsOf: [Float](repeating: 0.0005, count: Int(1.5 * rate)))
        for i in 0..<Int(2 * rate) { samples.append(Float(sin(Double(i) * 0.3) * 0.5)) }
        let features = AudioFeatureExtractor.extract(samples: samples, sampleRate: rate)
        let silences = SilenceDetector.detect(features, options: SilenceDetector.Options(thresholdDB: -40, minSilence: 0.5, padding: 0.1))
        XCTAssertEqual(silences.count, 1)
        XCTAssertEqual(silences[0].lowerBound, 2.1, accuracy: 0.05)
        XCTAssertEqual(silences[0].upperBound, 3.4, accuracy: 0.05)
        let kept = SilenceDetector.keptRanges(duration: 5.5, silences: silences)
        XCTAssertEqual(kept.count, 2)
        XCTAssertLessThan(SilenceDetector.autoThreshold(features), -25)
    }

    func testLoudnessOfSine() throws {
        // 997Hz・振幅 0.1 のサイン波（モノラル）は約 -23 LUFS
        let fs: Double = 48_000
        var samples: [Float] = []
        for i in 0..<Int(5 * fs) { samples.append(Float(0.1 * sin(2 * Double.pi * 997 * Double(i) / fs))) }
        let features = AudioFeatureExtractor.extract(samples: samples, sampleRate: fs)
        let lufs = try XCTUnwrap(Loudness.integratedLUFS(features))
        XCTAssertEqual(lufs, -23.0, accuracy: 0.7)
        let gain = Loudness.gain(for: features, targetLUFS: -14)
        // +9dB 上げたいが、最大値 0.1 なので割れない範囲（9.8 倍まで）
        XCTAssertEqual(Num.dB(fromLinear: gain), 9, accuracy: 0.8)
    }

    func testFeatureSerialization() {
        var f = AudioFeatures(frameRate: 100, sampleRate: 44_100, channels: 2)
        f.rms = [0.1, 0.2, 0.3]
        f.low = [0.01, 0.02, 0.03]
        f.peak = [0.5, 0.6, 0.7]
        f.kWeighted = [0.001, 0.002, 0.003]
        let decoded = AudioFeatures(data: f.serialized())
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.rms, f.rms)
        XCTAssertEqual(decoded?.peak, f.peak)
        XCTAssertEqual(decoded?.kWeighted, f.kWeighted)
        XCTAssertEqual(decoded?.channels, 2)
        XCTAssertNil(AudioFeatures(data: Data([1, 2, 3])))
        let wave = f.waveform(from: 0, to: 0.03, count: 3)
        XCTAssertEqual(wave, [0.5, 0.6, 0.7])
    }

    func testHighlightPick() {
        var f = AudioFeatures(frameRate: 100, sampleRate: 44_100, channels: 1)
        for i in 0..<3000 {
            let loud: Bool = i >= 1500 && i < 1800
            f.rms.append(loud ? 0.5 : 0.01)
            f.low.append(loud ? 0.3 : 0.005)
            f.peak.append(loud ? 0.8 : 0.02)
        }
        let segments = HighlightDetector.scores(f, window: 3)
        let picked = HighlightDetector.pick(segments, target: 3)
        XCTAssertEqual(picked.count, 1)
        XCTAssertEqual(picked[0].start, 15, accuracy: 1.0)
    }
}
