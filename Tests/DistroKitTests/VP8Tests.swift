import Foundation
import XCTest
@testable import DistroKit

/// VP8 の解読（Q71）。ffmpeg（libvpx と同じ結果になる解読器）の出力と 1 バイトも違わないことを、指紋（FNV-1a）で確かめる。
final class VP8Tests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let folder: URL = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return folder.appendingPathComponent(name)
    }

    /// 全部のコマの Y・U・V をつないだものの FNV-1a（64 ビット）と、コマの数と大きさ。
    private func decodeAll(_ name: String) throws -> (hash: UInt64, frames: Int, width: Int, height: Int) {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture(name))
        let track: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.codec == .vp8 })
        let decoder = VP8Decoder()
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        var frames: Int = 0
        var size: (Int, Int) = (0, 0)
        func mix(_ bytes: [UInt8]) {
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
        }
        while let packet = try demuxer.nextPacket() {
            if packet.track != track.number { continue }
            guard let image = try decoder.decode(packet.data) else { continue }
            mix(image.y)
            mix(image.u)
            mix(image.v)
            frames += 1
            size = (image.width, image.height)
        }
        return (hash, frames, size.0, size.1)
    }

    func testMatchesFFmpegOnWebMFixture() throws {
        let made = try decodeAll("vp8-vorbis.webm")
        XCTAssertEqual(made.frames, 30)
        XCTAssertEqual(made.width, 96)
        XCTAssertEqual(made.height, 64)
        XCTAssertEqual(made.hash, 0x226B_06A0_0F6A_5784)
    }

    /// 表示しない altref のフレーム・係数の区切り 4 つ・16 で割り切れない大きさ（176x100）。
    func testAltrefPartitionsAndOddSize() throws {
        let made = try decodeAll("vp8-altref.webm")
        XCTAssertEqual(made.frames, 30, "31 パケットのうち 1 つは表示しない")
        XCTAssertEqual(made.width, 176)
        XCTAssertEqual(made.height, 100)
        XCTAssertEqual(made.hash, 0xC3C8_2107_AAC4_CD25)
    }

    /// 版 1（双一次のフィルター・簡易ループフィルター）。
    func testBilinearProfile() throws {
        let made = try decodeAll("vp8-bilinear.webm")
        XCTAssertEqual(made.frames, 15)
        XCTAssertEqual(made.hash, 0xB17F_AF86_A7E6_7ABE)
    }

    func testRejectsBrokenFrames() {
        let decoder = VP8Decoder()
        XCTAssertThrowsError(try decoder.decode(Data([0x01, 0x02])))
        // キーフレームの印（9D 01 2A）が無い
        XCTAssertThrowsError(try decoder.decode(Data([0x50, 0x01, 0x00, 0x00, 0x00, 0x00, 0x60, 0x00, 0x40, 0x00, 0x00])))
        // 最初がキーフレームでない
        XCTAssertThrowsError(try decoder.decode(Data([0x01, 0x00, 0x00, 0x00])))
    }
}
