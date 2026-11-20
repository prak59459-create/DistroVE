import XCTest
@testable import DistroKit

/// MKV・WebM・AVI の読み取り（Q71）。見本は ffmpeg で作った 1 秒・96x64・30fps のファイル。
final class ForeignMediaTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        let folder: URL = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return folder.appendingPathComponent(name)
    }

    private func readAll(_ demuxer: ForeignDemuxer) throws -> [ForeignPacket] {
        var packets: [ForeignPacket] = []
        while let packet = try demuxer.nextPacket() {
            packets.append(packet)
        }
        return packets
    }

    private func track(_ demuxer: ForeignDemuxer, _ kind: ForeignTrackKind) throws -> ForeignTrack {
        return try XCTUnwrap(demuxer.tracks.first { $0.kind == kind })
    }

    func testMatroskaH264AACAndSubtitles() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("h264-aac-srt.mkv"))
        XCTAssertEqual(demuxer.containerName, "MKV")
        XCTAssertEqual(demuxer.duration, 1, accuracy: 0.1)
        let video: ForeignTrack = try track(demuxer, .video)
        XCTAssertEqual(video.codec, .h264)
        XCTAssertEqual(video.width, 96)
        XCTAssertEqual(video.height, 64)
        XCTAssertEqual(video.codecPrivate.first, 1, "avcC の最初は 1")
        let audio: ForeignTrack = try track(demuxer, .audio)
        XCTAssertEqual(audio.codec, .aac)
        XCTAssertEqual(audio.sampleRate, 48000)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertGreaterThanOrEqual(audio.codecPrivate.count, 2)
        let subtitle: ForeignTrack = try track(demuxer, .subtitle)
        XCTAssertEqual(subtitle.codec, .srt)
        XCTAssertEqual(subtitle.language, "jpn")

        let packets: [ForeignPacket] = try readAll(demuxer)
        let frames: [ForeignPacket] = packets.filter { $0.track == video.number }
        XCTAssertEqual(frames.count, 30)
        XCTAssertTrue(frames[0].keyframe)
        XCTAssertEqual(frames.filter { $0.keyframe }.count, 2, "15 コマごとのキーフレーム")
        let times: [Double] = frames.map { $0.time }.sorted()
        XCTAssertEqual(times.first ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(times.last ?? -1, 29.0 / 30, accuracy: 0.002)
        let sounds: [ForeignPacket] = packets.filter { $0.track == audio.number }
        XCTAssertGreaterThanOrEqual(sounds.count, 46)
        XCTAssertLessThanOrEqual(sounds.count, 49)

        let cues: [SubtitleCue] = ForeignContainer.cues(from: packets.filter { $0.track == subtitle.number }, codec: .srt)
        XCTAssertEqual(cues.map { $0.text }, ["こんにちは", "2 行目の字幕"])
        XCTAssertEqual(cues[0].start.seconds, 0.1, accuracy: 0.002)
        XCTAssertEqual(cues[0].end.seconds, 0.5, accuracy: 0.002)
    }

    func testMatroskaHEVCAndAC3() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("hevc-ac3.mkv"))
        let video: ForeignTrack = try track(demuxer, .video)
        XCTAssertEqual(video.codec, .hevc)
        XCTAssertFalse(video.codecPrivate.isEmpty, "hvcC")
        XCTAssertEqual(try track(demuxer, .audio).codec, .ac3)
        let packets: [ForeignPacket] = try readAll(demuxer)
        XCTAssertEqual(packets.filter { $0.track == video.number }.count, 30)
    }

    func testWebMVP9OpusAndVP8Vorbis() throws {
        let vp9: ForeignDemuxer = try ForeignContainer.open(url: try fixture("vp9-opus.webm"))
        XCTAssertEqual(vp9.containerName, "WebM")
        XCTAssertEqual(try track(vp9, .video).codec, .vp9)
        let opus: ForeignTrack = try track(vp9, .audio)
        XCTAssertEqual(opus.codec, .opus)
        XCTAssertEqual(String(decoding: opus.codecPrivate.prefix(8), as: UTF8.self), "OpusHead")
        XCTAssertGreaterThan(opus.codecDelay, 0)
        XCTAssertEqual(try readAll(vp9).filter { $0.track == 1 || $0.track == 2 }.isEmpty, false)

        let vp8: ForeignDemuxer = try ForeignContainer.open(url: try fixture("vp8-vorbis.webm"))
        XCTAssertEqual(try track(vp8, .video).codec, .vp8)
        XCTAssertEqual(try track(vp8, .audio).codec, .vorbis)
        let number: Int = try track(vp8, .video).number
        let frames: [ForeignPacket] = try readAll(vp8).filter { $0.track == number }
        XCTAssertEqual(frames.count, 30)
    }

    func testAVIMotionJPEGAndPCM() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("mjpeg-pcm.avi"))
        XCTAssertEqual(demuxer.containerName, "AVI")
        XCTAssertEqual(demuxer.duration, 1, accuracy: 0.05)
        let video: ForeignTrack = try track(demuxer, .video)
        XCTAssertEqual(video.codec, .mjpeg)
        XCTAssertEqual(video.width, 96)
        XCTAssertEqual(video.height, 64)
        XCTAssertEqual(video.defaultDuration, 1.0 / 30, accuracy: 0.0001)
        let audio: ForeignTrack = try track(demuxer, .audio)
        XCTAssertEqual(audio.codec, .pcm)
        XCTAssertEqual(audio.sampleRate, 22050)
        XCTAssertEqual(audio.channels, 1)
        XCTAssertEqual(audio.bitsPerSample, 16)
        let packets: [ForeignPacket] = try readAll(demuxer)
        let frames: [ForeignPacket] = packets.filter { $0.track == video.number }
        XCTAssertEqual(frames.count, 30)
        XCTAssertTrue(frames.allSatisfy { $0.keyframe })
        XCTAssertEqual(frames[10].time, 10.0 / 30, accuracy: 0.0001)
        XCTAssertEqual(frames[0].data.prefix(2), Data([0xFF, 0xD8]), "JPEG の始まり")
        let bytes: Int = packets.filter { $0.track == audio.number }.reduce(0) { $0 + $1.data.count }
        XCTAssertEqual(Double(bytes), 22050 * 2, accuracy: 2048)
    }

    func testAVIMPEG4AndMP3() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("mpeg4-mp3.avi"))
        let video: ForeignTrack = try track(demuxer, .video)
        XCTAssertEqual(video.codec, .mpeg4)
        XCTAssertEqual(try track(demuxer, .audio).codec, .mp3)
        let frames: [ForeignPacket] = try readAll(demuxer).filter { $0.track == video.number }
        XCTAssertEqual(frames.count, 30)
        XCTAssertEqual(frames.filter { $0.keyframe }.count, 2)
        XCTAssertTrue(AVIReader.isKeyframe(.mpeg4, frames[0].data))
        XCTAssertFalse(AVIReader.isKeyframe(.mpeg4, frames[1].data))
    }

    func testFLACInMatroska() throws {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: try fixture("flac.mkv"))
        let audio: ForeignTrack = try track(demuxer, .audio)
        XCTAssertEqual(audio.codec, .flac)
        XCTAssertEqual(String(decoding: audio.codecPrivate.prefix(4), as: UTF8.self), "fLaC")
        XCTAssertNil(demuxer.tracks.first { $0.kind == .video })
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try ForeignContainer.open(data: Data("not a movie".utf8))) { error in
            XCTAssertEqual(error as? ForeignMediaError, .notRecognized)
        }
    }

    // MARK: 手で作った EBML（まとめ方・大きさ不明のクラスター）

    private func element(_ id: [UInt8], _ body: [UInt8]) -> [UInt8] {
        return id + ebmlSize(body.count) + body
    }

    private func ebmlSize(_ n: Int) -> [UInt8] {
        if n < 0x7F { return [UInt8(0x80 | n)] }
        return [0x40 | UInt8((n >> 8) & 0x3F), UInt8(n & 0xFF)]
    }

    private func minimalMatroska(clusterBody: [UInt8], unknownSize: Bool) -> Data {
        let header: [UInt8] = element([0x1A, 0x45, 0xDF, 0xA3], element([0x42, 0x82], Array("matroska".utf8)))
        let track: [UInt8] = element([0xAE], element([0xD7], [1]) + element([0x83], [2]) + element([0x86], Array("A_MPEG/L3".utf8))
            + element([0x23, 0xE3, 0x83], [0x01, 0x8E, 0x98, 0xD1]))
        let tracks: [UInt8] = element([0x16, 0x54, 0xAE, 0x6B], track)
        let cluster: [UInt8]
        if unknownSize {
            cluster = [0x1F, 0x43, 0xB6, 0x75, 0xFF] + clusterBody
        } else {
            cluster = element([0x1F, 0x43, 0xB6, 0x75], clusterBody)
        }
        let segmentBody: [UInt8] = tracks + cluster
        let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + segmentBody
        return Data(header + segment)
    }

    func testLacingAndUnknownSizeCluster() throws {
        // トラック 1・時刻 +10・キーフレーム・Xiph のまとめ方で 3 つ（2・3・残り 4 バイト）
        let xiph: [UInt8] = [0x81, 0x00, 0x0A, 0x80 | 0x02, 0x02, 0x02, 0x03, 1, 1, 2, 2, 2, 3, 3, 3, 3]
        // EBML のまとめ方で 3 つ（3・差 -1 で 2・残り 1 バイト）
        let ebml: [UInt8] = [0x81, 0x00, 0x14, 0x80 | 0x06, 0x02, 0x83, 0xBE, 7, 7, 7, 8, 8, 9]
        // 固定長で 2 つ（2 バイトずつ）
        let fixed: [UInt8] = [0x81, 0x00, 0x1E, 0x80 | 0x04, 0x01, 5, 5, 6, 6]
        let body: [UInt8] = element([0xE7], [0x64]) + element([0xA3], xiph) + element([0xA3], ebml) + element([0xA3], fixed)
        for unknown in [false, true] {
            let demuxer: ForeignDemuxer = try ForeignContainer.open(data: minimalMatroska(clusterBody: body, unknownSize: unknown))
            let packets: [ForeignPacket] = try readAll(demuxer)
            XCTAssertEqual(packets.map { $0.data.count }, [2, 3, 4, 3, 2, 1, 2, 2], "unknown=\(unknown)")
            XCTAssertEqual(packets[3].data, Data([7, 7, 7]))
            XCTAssertEqual(packets[5].data, Data([9]))
            // クラスター 100ms + 10ms、まとめた 2 つ目は DefaultDuration（約 26.1ms）だけ後
            XCTAssertEqual(packets[0].time, 0.110, accuracy: 0.0001)
            XCTAssertEqual(packets[1].time, 0.110 + 0.026122, accuracy: 0.0001)
        }
    }

    func testASSText() {
        let line: String = "3,0,Default,,0,0,0,,{\\b1}太字{\\b0}と、カンマ\\N改行"
        XCTAssertEqual(ForeignContainer.assText(line), "太字と、カンマ\n改行")
    }
}
