#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import DistroKit

/// 逆再生の音声（Q34）。上がっていく音の波形が、逆再生では下がっていくこと。
final class ReverseAudioTests: XCTestCase {
    func testReversedAudioRunsBackwards() async throws {
        let folder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("distrove-reverse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // 7 秒・48kHz・モノラルの、0 から 0.9 まで上がる波形（5 秒ごとの読み取りの区切りをまたぐ長さ）
        let rate: Double = 48_000
        let frames: Int = Int(rate * 7)
        let source: URL = folder.appendingPathComponent("ramp.wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return XCTFail("バッファーを作れません")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            buffer.floatChannelData![0][i] = 0.9 * Float(i) / Float(frames)
        }
        do {
            let writer = try AVAudioFile(forWriting: source, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        let output: URL = folder.appendingPathComponent("reversed.caf")
        try await MediaJobs.makeReversedAudio(from: AVURLAsset(url: source), duration: Time(seconds: 7), to: output)

        let reversed = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(reversed.length), Double(frames), accuracy: rate * 0.02)
        let count: AVAudioFrameCount = AVAudioFrameCount(reversed.length)
        let read: AVAudioPCMBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: reversed.processingFormat, frameCapacity: count))
        try reversed.read(into: read)
        let samples: UnsafeMutablePointer<Float> = try XCTUnwrap(read.floatChannelData?[0])
        let n: Int = Int(read.frameLength)
        XCTAssertEqual(Double(samples[100]), 0.9, accuracy: 0.02, "最初は大きい値")
        XCTAssertEqual(Double(samples[n - 100]), 0, accuracy: 0.02, "最後は小さい値")
        // 5 秒の区切り（逆にした 2 秒目のあたり）でも、なめらかに下がっている
        var rising: Int = 0
        for i in stride(from: 1, to: n, by: 97) where samples[i] > samples[i - 1] + 0.001 {
            rising += 1
        }
        XCTAssertEqual(rising, 0)
    }
}
#endif
