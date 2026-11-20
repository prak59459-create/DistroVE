import Foundation
import XCTest
@testable import DistroKit

/// FLV の読み取り（Q71）。見本は ffmpeg で作った H.264（B フレームあり）・AAC と、Sorenson Spark・MP3。
final class FLVTests: XCTestCase {
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

    func testFLVH264AndAAC() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("h264-aac.flv"))
        XCTAssertEqual(demuxer.containerName, "FLV")
        XCTAssertEqual(demuxer.duration, 1.067, accuracy: 0.05)
        let video: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .video })
        let audio: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .audio })
        XCTAssertEqual(video.codec, .h264)
        XCTAssertEqual(video.width, 96, "onMetaData の幅")
        XCTAssertEqual(video.height, 64, "onMetaData の高さ")
        XCTAssertEqual(video.codecPrivate.first, 1, "avcC の版")
        XCTAssertEqual(audio.codec, .aac)
        XCTAssertGreaterThanOrEqual(audio.codecPrivate.count, 2, "AudioSpecificConfig")
        XCTAssertEqual(audio.codecPrivate.first.map { $0 >> 3 }, 2, "AAC LC")
        XCTAssertEqual(audio.channels, 2)
        let list: [ForeignPacket] = try packets(demuxer)
        let frames: [ForeignPacket] = list.filter { $0.track == video.number }
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(list.filter { $0.track == audio.number }.count, 45)
        XCTAssertEqual(frames.filter { $0.keyframe }.count, 2)
        // 表示の時刻（解読の時刻 + composition time）は、並べ直すと 1/30 秒ずつ
        let times: [Double] = frames.map { $0.time }.sorted()
        XCTAssertEqual(times[0], 0.067, accuracy: 0.002)
        for i in 1..<times.count {
            XCTAssertEqual(times[i] - times[i - 1], 1.0 / 30, accuracy: 0.002)
        }
        XCTAssertNotEqual(frames.map { $0.time }, times, "B フレームがあるので届く順は表示の順と違う")
    }

    func testFLVFlashOnlyCodecsAreNamed() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("sorenson-mp3.flv"))
        let video: ForeignTrack = try XCTUnwrap(demuxer.tracks.first { $0.kind == .video })
        XCTAssertEqual(video.codec, .unknown)
        XCTAssertEqual(video.codecLabel, "Sorenson Spark（H.263）")
        XCTAssertEqual(try XCTUnwrap(demuxer.tracks.first { $0.kind == .audio }).codec, .mp3)
    }

    func testMetadataDuration() {
        var data = Data([0x02, 0x00, 0x0A])
        data.append(Data("onMetaData".utf8))
        data.append(Data([0x08, 0, 0, 0, 1, 0x00, 0x08]))
        data.append(Data("duration".utf8))
        data.append(0x00)
        var value: UInt64 = (2.5 as Double).bitPattern.bigEndian
        data.append(Data(bytes: &value, count: 8))
        XCTAssertEqual(FLVReader.metadataDuration(data), 2.5)
    }
}
