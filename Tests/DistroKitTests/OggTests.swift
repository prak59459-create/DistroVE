import Foundation
import XCTest
@testable import DistroKit

/// Ogg（.ogg・.opus・.oga）の読み取り（Q71）。見本は ffmpeg で作った 1 秒の音。
final class OggTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let folder: URL = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return folder.appendingPathComponent(name)
    }

    private func packets(_ demuxer: ForeignDemuxer) throws -> [ForeignPacket] {
        var list: [ForeignPacket] = []
        while let packet = try demuxer.nextPacket() {
            list.append(packet)
        }
        return list
    }

    func testOggVorbisDecodes() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("tone.ogg"))
        XCTAssertEqual(demuxer.containerName, "Ogg")
        XCTAssertEqual(demuxer.duration, 1, accuracy: 0.01)
        let track: ForeignTrack = try XCTUnwrap(demuxer.tracks.first)
        XCTAssertEqual(track.codec, .vorbis)
        XCTAssertEqual(track.channels, 1)
        XCTAssertEqual(track.sampleRate, 22_050)
        let decoder = try VorbisDecoder(codecPrivate: track.codecPrivate)
        var samples: [Float] = []
        for packet in try packets(demuxer) where packet.track == track.number {
            samples.append(contentsOf: decoder.decode(packet.data).first ?? [])
        }
        XCTAssertEqual(Double(samples.count), 22_050, accuracy: 1_024)
        // ffmpeg（libvorbis）で解読した値
        XCTAssertEqual(Double(samples[1_000]), -0.1229238, accuracy: 1e-5)
        XCTAssertEqual(Double(samples[11_025]), -0.0035377, accuracy: 1e-5)
        XCTAssertEqual(Double(samples[20_000]), 0.0900791, accuracy: 1e-5)
    }

    func testOggOpusTrack() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("tone.opus"))
        XCTAssertEqual(demuxer.duration, 1, accuracy: 0.02)
        let track: ForeignTrack = try XCTUnwrap(demuxer.tracks.first)
        XCTAssertEqual(track.codec, .opus)
        XCTAssertEqual(track.channels, 1)
        XCTAssertEqual(String(decoding: track.codecPrivate.prefix(8), as: UTF8.self), "OpusHead")
        XCTAssertGreaterThan(track.codecDelay, 0)
        let list: [ForeignPacket] = try packets(demuxer)
        XCTAssertGreaterThanOrEqual(list.count, 45, "20 ミリ秒ずつのパケットが 1 秒分")
        XCTAssertFalse(list.contains { String(decoding: $0.data.prefix(8), as: UTF8.self) == "OpusTags" }, "見出しは音声に混ざらない")
    }

    func testOggFLACTrack() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("tone-flac.oga"))
        let track: ForeignTrack = try XCTUnwrap(demuxer.tracks.first)
        XCTAssertEqual(track.codec, .flac)
        XCTAssertEqual(track.sampleRate, 44_100)
        XCTAssertEqual(track.channels, 1)
        XCTAssertEqual(track.bitsPerSample, 16)
        XCTAssertEqual(String(decoding: track.codecPrivate.prefix(4), as: UTF8.self), "fLaC")
        let list: [ForeignPacket] = try packets(demuxer)
        XCTAssertFalse(list.isEmpty)
        for packet in list {
            XCTAssertEqual(packet.data.first, 0xFF, "FLAC のかたまりの始まり")
        }
    }

    func testFormatTablesKnowOgg() {
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "opus"), .audio)
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "ogg"), .audio)
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "ogv"), .video)
        XCTAssertNil(MediaFormatSupport.unsupportedReason(forExtension: "ogg"))
    }
}
