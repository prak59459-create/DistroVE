import Foundation
import XCTest
@testable import DistroKit

/// MPEG-TS・M2TS（AVCHD）の読み取り（Q71）。見本は ffmpeg で作った 1 秒・96x64・30fps のファイル。
final class MPEGTSTests: XCTestCase {
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

    /// 表示の時刻を並べ直すと 1/30 秒ずつ。時刻は音声と同じ基準（一番早い PTS）からなので、最初のコマは 0 秒の少しあと。
    private func checkVideoTimes(_ frames: [ForeignPacket], file: StaticString = #filePath, line: UInt = #line) {
        let times: [Double] = frames.map { $0.time }.sorted()
        let first: Double = times.first ?? -1
        XCTAssertGreaterThanOrEqual(first, 0, file: file, line: line)
        XCTAssertLessThan(first, 0.05, "最初のコマは 0 秒の近く", file: file, line: line)
        for i in 1..<times.count {
            XCTAssertEqual(times[i] - times[i - 1], 1.0 / 30, accuracy: 0.002, file: file, line: line)
        }
    }

    func testM2TSWithH264AndAC3() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("h264-ac3.m2ts"))
        XCTAssertEqual(demuxer.containerName, "M2TS")
        XCTAssertEqual(demuxer.duration, 1, accuracy: 0.1)
        let video: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .video })
        let audio: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .audio })
        XCTAssertEqual(video.codec, .h264)
        XCTAssertEqual(audio.codec, .ac3)
        let list: [ForeignPacket] = try packets(demuxer)
        let frames: [ForeignPacket] = list.filter { $0.track == video.number }
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.filter { $0.keyframe }.count, 2)
        XCTAssertTrue(frames[0].keyframe)
        checkVideoTimes(frames)
        let sound: [ForeignPacket] = list.filter { $0.track == audio.number }
        XCTAssertFalse(sound.isEmpty)
        XCTAssertEqual(Array(sound[0].data.prefix(2)), [0x0B, 0x77], "AC-3 の同期語")
    }

    func testTSWithHEVCAndAAC() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("hevc-aac.ts"))
        XCTAssertEqual(demuxer.containerName, "MPEG-TS")
        let video: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .video })
        let audio: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .audio })
        XCTAssertEqual(video.codec, .hevc)
        XCTAssertEqual(audio.codec, .aac)
        XCTAssertEqual(audio.codecName, "adts")
        let list: [ForeignPacket] = try packets(demuxer)
        let frames: [ForeignPacket] = list.filter { $0.track == video.number }
        XCTAssertEqual(frames.count, 30)
        XCTAssertGreaterThanOrEqual(frames.filter { $0.keyframe }.count, 2)
        checkVideoTimes(frames)
        let sound: [ForeignPacket] = list.filter { $0.track == audio.number }
        let first: [UInt8] = Array(try XCTUnwrap(sound.first).data.prefix(2))
        XCTAssertEqual(first[0], 0xFF, "ADTS の同期語")
        XCTAssertEqual(first[1] & 0xF0, 0xF0)
    }

    func testTSWithMPEG2AndMP2() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("mpeg2-mp2.ts"))
        let video: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .video })
        let audio: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .audio })
        XCTAssertEqual(video.codec, .mpeg2)
        XCTAssertEqual(video.width, 96, "sequence header の幅")
        XCTAssertEqual(video.height, 64)
        XCTAssertEqual(audio.codec, .mp2, "Layer II")
        let frames: [ForeignPacket] = try packets(demuxer).filter { $0.track == video.number }
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.filter { $0.keyframe }.count, 3, "ffprobe と同じく I ピクチャーは 3 つ（最後のコマも I）")
        checkVideoTimes(frames)
    }

    func testFormatTablesKnowTS() {
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "MTS"), .video)
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "m2ts"), .video)
        XCTAssertNil(MediaFormatSupport.unsupportedReason(forExtension: "ts"))
        XCTAssertTrue(ForeignContainer.extensions.contains("mts"))
    }
}
