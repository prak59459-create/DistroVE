import Foundation
import XCTest
@testable import DistroKit

/// Vorbis の解読（Q71）。見本は libvorbis で作ったファイルで、元の音（式で作った音）と比べる。
final class VorbisTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let folder: URL = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return folder.appendingPathComponent(name)
    }

    /// ファイルの Vorbis を全部解読して、チャンネルごとにつなげる。
    private func decodeAll(_ name: String) throws -> (decoder: VorbisDecoder, samples: [[Float]]) {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture(name))
        let track: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.codec == .vorbis })
        let decoder = try VorbisDecoder(codecPrivate: track.codecPrivate)
        var samples: [[Float]] = Array(repeating: [], count: decoder.channels)
        while let packet = try demuxer.nextPacket() {
            if packet.track != track.number { continue }
            let block: [[Float]] = decoder.decode(packet.data)
            for (channel, values) in block.enumerated() {
                samples[channel].append(contentsOf: values)
            }
        }
        return (decoder, samples)
    }

    func testFastIMDCTMatchesTheFormula() {
        var seed: UInt32 = 7
        for size in [64, 256, 2048] {
            var spectrum: [Float] = []
            for _ in 0..<(size / 2) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                spectrum.append(Float(seed >> 8) / 16_777_216 * 2 - 1)
            }
            var fast: [Float] = Array(repeating: 0, count: size)
            VorbisIMDCT(size: size).inverse(spectrum, into: &fast)
            let slow: [Float] = VorbisIMDCT.slowInverse(spectrum, size: size)
            var worst: Float = 0
            var peak: Float = 0
            for i in 0..<size {
                worst = max(worst, abs(fast[i] - slow[i]))
                peak = max(peak, abs(slow[i]))
            }
            XCTAssertLessThan(worst, peak * 1e-4, "大きさ \(size)")
        }
    }

    func testXiphLacing() throws {
        // 3 つ（300 バイト・2 バイト・残り 4 バイト）
        var data = Data([2, 255, 45, 2])
        data.append(Data(repeating: 1, count: 300))
        data.append(Data([7, 8]))
        data.append(Data([9, 9, 9, 9]))
        let packets: [Data] = try XCTUnwrap(VorbisDecoder.xiphPackets(data))
        XCTAssertEqual(packets.map { $0.count }, [300, 2, 4])
        XCTAssertEqual(packets[1], Data([7, 8]))
    }

    /// 左右で違う音と、短いブロックを使わせる「カチッ」という音（0.5 秒・1.0 秒）。
    private func original(_ frames: Int) -> [[Float]] {
        let rate: Double = 44_100
        var left: [Float] = []
        var right: [Float] = []
        for i in 0..<frames {
            let t: Double = Double(i) / rate
            var l: Double = 0.3 * sin(2 * Double.pi * 440 * t) + 0.15 * sin(2 * Double.pi * 1320 * t)
            var r: Double = 0.3 * sin(2 * Double.pi * 660 * t) + 0.1 * sin(2 * Double.pi * 2640 * t)
            for c in [0.5, 1.0] {
                let d: Double = t - c
                if d >= 0 && d < 0.004 {
                    let click: Double = 0.5 * exp(-d * 1500) * sin(2 * Double.pi * 3000 * d)
                    l += click
                    r -= click
                }
            }
            left.append(Float(l))
            right.append(Float(r))
        }
        return [left, right]
    }

    func testDecodesStereoLikeTheOriginal() throws {
        let made = try decodeAll("vorbis-stereo.mka")
        XCTAssertEqual(made.decoder.channels, 2)
        XCTAssertEqual(made.decoder.sampleRate, 44_100)
        // ffmpeg（libvorbis）で解読した結果と、長さも値も同じになる
        XCTAssertEqual(made.samples[0].count, 66_368)
        let reference: [(frame: Int, left: Float, right: Float)] = [
            (5_000, -0.3246283, -0.1729371), (22_050, 0.0002734, -0.0528476), (22_100, 0.0639997, -0.3446722),
            (44_150, 0.0711088, -0.3547959), (60_000, -0.3065250, -0.1613846)
        ]
        for point in reference {
            XCTAssertEqual(Double(made.samples[0][point.frame]), Double(point.left), accuracy: 1e-5)
            XCTAssertEqual(Double(made.samples[1][point.frame]), Double(point.right), accuracy: 1e-5)
        }
        let source: [[Float]] = original(made.samples[0].count)
        for channel in 0..<2 {
            var signal: Double = 0
            var noise: Double = 0
            for i in 2_000..<62_000 {
                let s: Double = Double(source[channel][i])
                let d: Double = Double(made.samples[channel][i]) - s
                signal += s * s
                noise += d * d
            }
            let snr: Double = 10 * log10(signal / max(noise, 1e-12))
            XCTAssertGreaterThan(snr, 20, "チャンネル \(channel) の SN 比 \(snr) dB")
        }
    }

    func testDecodesWebMVorbisTrack() throws {
        let made = try decodeAll("vp8-vorbis.webm")
        XCTAssertEqual(made.decoder.channels, 2)
        XCTAssertEqual(made.decoder.sampleRate, 48_000)
        XCTAssertEqual(made.samples[0].count, 48_704)
        XCTAssertEqual(Double(made.samples[0][1_000]), 0.0755067, accuracy: 1e-5)
        XCTAssertEqual(Double(made.samples[1][40_000]), -0.0774779, accuracy: 1e-5)
        var energy: Double = 0
        for value in made.samples[0] {
            energy += Double(value) * Double(value)
        }
        let rms: Double = (energy / Double(max(1, made.samples[0].count))).squareRoot()
        XCTAssertGreaterThan(rms, 0.01, "音が出ている")
        XCTAssertLessThan(rms, 1, "大きすぎない")
    }

    func testFiveOneBecomesStereo() {
        let ones: [Float] = Array(repeating: 1, count: 4)
        let zeros: [Float] = Array(repeating: 0, count: 4)
        // 左前だけ鳴っている 5.1
        let mixed: [[Float]] = VorbisDecoder.stereo([ones, zeros, zeros, zeros, zeros, zeros])
        XCTAssertEqual(mixed.count, 2)
        XCTAssertGreaterThan(mixed[0][0], 0.3)
        XCTAssertEqual(mixed[1][0], 0)
        // 全部鳴っていても 1 を超えない
        let loud: [[Float]] = VorbisDecoder.stereo(Array(repeating: ones, count: 6))
        XCTAssertLessThanOrEqual(loud[0][0], 1.0001)
    }
}
