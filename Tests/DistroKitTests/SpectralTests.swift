import XCTest
@testable import DistroKit

/// FFT・ノイズ除去（Q53）・話者の自動判別（Q57）。
final class SpectralTests: XCTestCase {
    /// 決まった乱数（毎回同じ結果にする）。
    private struct Noise {
        var state: UInt32 = 12345
        mutating func next() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / 16_777_216 * 2 - 1
        }
    }

    func testFFTRoundTrip() {
        var real: [Float] = (0..<256).map { sin(Float($0) * 0.3) + 0.5 * cos(Float($0) * 1.7) }
        let original: [Float] = real
        var imag: [Float] = Array(repeating: 0, count: 256)
        RadixFFT.transform(&real, &imag, inverse: false)
        RadixFFT.transform(&real, &imag, inverse: true)
        for i in 0..<256 {
            XCTAssertEqual(Double(real[i]), Double(original[i]), accuracy: 1e-4)
        }
    }

    func testDenoiseKeepsToneAndRemovesNoise() {
        let rate: Float = 16_000
        var noise = Noise()
        var clean: [Float] = []
        var noisy: [Float] = []
        for i in 0..<Int(rate * 2) {
            let tone: Float = i < Int(rate / 2) ? 0 : 0.3 * sin(2 * Float.pi * 440 * Float(i) / rate)
            clean.append(tone)
            noisy.append(tone + 0.06 * noise.next())
        }
        let output: [Float] = SpectralDenoiser.process(noisy, strength: 0.8)
        func energy(_ a: [Float], _ range: Range<Int>) -> Float {
            return range.reduce(0) { $0 + a[$1] * a[$1] }
        }
        let quiet: Range<Int> = 2000..<7000
        XCTAssertLessThan(energy(output, quiet), energy(noisy, quiet) * 0.25, "雑音だけの所は 6dB 以上下がる")
        let loud: Range<Int> = 12000..<30000
        let before: Float = loud.reduce(0) { $0 + (noisy[$1] - clean[$1]) * (noisy[$1] - clean[$1]) }
        let after: Float = loud.reduce(0) { $0 + (output[$1] - clean[$1]) * (output[$1] - clean[$1]) }
        XCTAssertLessThan(after, before * 0.6, "音のある所でも雑音が減る")
        XCTAssertGreaterThan(energy(output, loud), energy(clean, loud) * 0.7, "音そのものは残る")
    }

    /// 声の高さと明るさの違う 2 人の「声」（倍音つきの音）。
    private func voice(pitch: Float, brightness: Float, seconds: Float, seed: UInt32) -> [Float] {
        let rate: Float = 16_000
        var noise = Noise(state: seed)
        var result: [Float] = []
        for i in 0..<Int(rate * seconds) {
            let t: Float = Float(i) / rate
            var v: Float = 0
            for h in 1...12 {
                let weight: Float = pow(brightness, Float(h - 1)) / Float(h)
                v += weight * sin(2 * Float.pi * pitch * Float(h) * t)
            }
            result.append(0.2 * v + 0.005 * noise.next())
        }
        return result
    }

    func testSpeakersAreSeparated() {
        let order: [Bool] = [true, false, true, true, false, false]
        var features: [[Double]] = []
        for (i, isLow) in order.enumerated() {
            let samples: [Float] = isLow ? voice(pitch: 115, brightness: 0.5, seconds: 0.8, seed: UInt32(i + 1))
                : voice(pitch: 230, brightness: 0.85, seconds: 0.8, seed: UInt32(i + 1))
            features.append(SpeakerClustering.features(samples, sampleRate: 16_000) ?? [])
        }
        XCTAssertEqual(SpeakerClustering.assign(features), [0, 1, 0, 0, 1, 1])
        XCTAssertEqual(SpeakerClustering.assign(features, speakers: 2), [0, 1, 0, 0, 1, 1])
        let pitch: Double = SpeakerClustering.pitch(voice(pitch: 200, brightness: 0.5, seconds: 0.2, seed: 9), at: 0, length: 512, sampleRate: 16_000) ?? 0
        XCTAssertEqual(pitch, 200, accuracy: 8)
    }

    /// 長い区間は真ん中だけを見る（前後に別の声があっても、真ん中の声の特徴になる）。
    func testLongSegmentsUseTheMiddle() throws {
        let edge: [Float] = voice(pitch: 115, brightness: 0.5, seconds: 3, seed: 3)
        let middle: [Float] = voice(pitch: 230, brightness: 0.85, seconds: 2, seed: 4)
        let mixed: [Float] = edge + middle + edge
        let limited: [Double] = try XCTUnwrap(SpeakerClustering.features(mixed, sampleRate: 16_000, maxSeconds: 2))
        let alone: [Double] = try XCTUnwrap(SpeakerClustering.features(middle, sampleRate: 16_000))
        XCTAssertEqual(limited[0], alone[0], accuracy: 0.3, "声の高さは真ん中の声のもの")
        XCTAssertEqual(limited[0], log2(2.3) * 4, accuracy: 0.3)
    }

    func testOneSpeakerStaysTogether() {
        var features: [[Double]] = []
        for i in 0..<5 {
            let samples: [Float] = voice(pitch: 140 + Float(i), brightness: 0.6, seconds: 0.6, seed: UInt32(i + 7))
            features.append(SpeakerClustering.features(samples, sampleRate: 16_000) ?? [])
        }
        XCTAssertEqual(Set(SpeakerClustering.assign(features)).count, 1)
    }
}
