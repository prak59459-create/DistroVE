#if canImport(VideoToolbox) && canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import DistroKit

/// MKV・WebM・AVI を MP4 に変える（Q71）。macOS の VideoToolbox・AudioToolbox を実際に使う。
final class ForeignConversionTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distrove-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
    }

    override func tearDown() {
        AppPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> URL {
        let folder: URL = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        return folder.appendingPathComponent(name)
    }

    private func convert(_ name: String) async throws -> ForeignMediaConverter.Result {
        AppPaths.ensure(AppPaths.media)
        return try await ForeignMediaConverter.convert(try fixture(name), into: AppPaths.media, progress: nil)
    }

    /// 変換したファイルの中身を確かめる。映像があればコマ数と絵の中身も見る。
    private func check(_ result: ForeignMediaConverter.Result, video: Bool, audio: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let asset = AVURLAsset(url: result.url)
        let duration: Double = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.2, "長さ", file: file, line: line)
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        let audioTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(!videoTracks.isEmpty, video, "映像の有無", file: file, line: line)
        XCTAssertEqual(!audioTracks.isEmpty, audio, "音声の有無 \(result.notes)", file: file, line: line)
        guard let track = videoTracks.first else { return }
        let size: CGSize = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 96, file: file, line: line)
        XCTAssertEqual(size.height, 64, file: file, line: line)
        let reader = try AVAssetReader(asset: asset)
        var settings: [String: Any] = [:]
        settings[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading(), file: file, line: line)
        var frames: Int = 0
        var spread: Int = 0
        while let sample = output.copyNextSampleBuffer() {
            frames += 1
            if frames == 10, let buffer = CMSampleBufferGetImageBuffer(sample) {
                spread = brightnessSpread(buffer)
            }
        }
        XCTAssertGreaterThanOrEqual(frames, 28, file: file, line: line)
        XCTAssertLessThanOrEqual(frames, 31, file: file, line: line)
        // testsrc2 の色の縞が写っている（真っ黒や一色ではない）
        XCTAssertGreaterThan(spread, 60, file: file, line: line)
    }

    private func brightnessSpread(_ buffer: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(buffer)
        var low: Int = 255
        var high: Int = 0
        for y in stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 4) {
            for x in stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 4) {
                let g: Int = Int(base[y * bytesPerRow + x * 4 + 1])
                low = min(low, g)
                high = max(high, g)
            }
        }
        return high - low
    }

    func testMatroskaH264AACWithSubtitles() async throws {
        let result = try await convert("h264-aac-srt.mkv")
        XCTAssertEqual(result.kind, .video)
        XCTAssertEqual(result.container, "MKV")
        try await check(result, video: true, audio: true)
        XCTAssertEqual(result.subtitles.map { $0.text }, ["こんにちは", "2 行目の字幕"])
    }

    func testMatroskaHEVCAndAC3() async throws {
        let result = try await convert("hevc-ac3.mkv")
        let hasAudio: Bool = result.notes.isEmpty
        try await check(result, video: true, audio: hasAudio)
    }

    func testAVIMotionJPEGAndPCM() async throws {
        let result = try await convert("mjpeg-pcm.avi")
        XCTAssertEqual(result.container, "AVI")
        try await check(result, video: true, audio: true)
    }

    func testAVIMPEG4AndMP3() async throws {
        let result = try await convert("mpeg4-mp3.avi")
        try await check(result, video: true, audio: true)
    }

    func testAudioOnlyFLACAndOpus() async throws {
        let flac = try await convert("flac.mkv")
        XCTAssertEqual(flac.kind, .audio)
        XCTAssertEqual(flac.url.pathExtension, "m4a")
        try await check(flac, video: false, audio: true)
        let opus = try await convert("opus.mka")
        XCTAssertEqual(opus.kind, .audio)
        try await check(opus, video: false, audio: true)
    }

    /// VP9 は端末によって読めるかが変わる。読めないときは、何が読めないかを伝える。
    func testWebMVP9EitherConvertsOrExplains() async throws {
        do {
            let result = try await convert("vp9-opus.webm")
            try await check(result, video: true, audio: true)
        } catch let EngineError.unsupported(message) {
            XCTAssertTrue(message.contains("VP9"), message)
        }
    }

    /// VP8（自前の解読器）と Vorbis（自前の解読器）の WebM。
    func testWebMVP8AndVorbis() async throws {
        let result = try await convert("vp8-vorbis.webm")
        XCTAssertEqual(result.container, "WebM")
        XCTAssertTrue(result.notes.isEmpty, "\(result.notes)")
        try await check(result, video: true, audio: true)
    }

    /// 表示しない altref のフレームを含む VP8。
    func testWebMVP8WithAltref() async throws {
        let result = try await convert("vp8-altref.webm")
        let asset = AVURLAsset(url: result.url)
        let tracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        let track: AVAssetTrack = try XCTUnwrap(tracks.first)
        let size: CGSize = try await track.load(.naturalSize)
        XCTAssertEqual(size.width, 176)
        XCTAssertEqual(size.height, 100)
        let duration: Double = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.15)
    }

    /// Vorbis（自前の解読器）の音声だけの MKV。
    func testMatroskaVorbisAudio() async throws {
        let result = try await convert("vorbis-stereo.mka")
        XCTAssertEqual(result.kind, .audio)
        XCTAssertTrue(result.notes.isEmpty, "\(result.notes)")
        let asset = AVURLAsset(url: result.url)
        let duration: Double = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.5, accuracy: 0.1)
        let tracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }

    /// Ogg の Vorbis・Opus・FLAC（1 つずつ）。
    private func checkOgg(_ name: String) async throws {
        let result = try await convert(name)
        XCTAssertEqual(result.kind, .audio, name)
        XCTAssertEqual(result.container, "Ogg", name)
        XCTAssertTrue(result.notes.isEmpty, "\(name): \(result.notes)")
        try await check(result, video: false, audio: true)
    }

    func testOggVorbis() async throws {
        try await checkOgg("tone.ogg")
    }

    func testOggOpus() async throws {
        try await checkOgg("tone.opus")
    }

    func testOggFLAC() async throws {
        try await checkOgg("tone-flac.oga")
    }

    /// FLV の H.264（B フレームあり）・AAC。
    func testFLVH264AndAAC() async throws {
        let result = try await convert("h264-aac.flv")
        XCTAssertEqual(result.container, "FLV")
        try await check(result, video: true, audio: true)
    }

    /// Flash だけの映像（Sorenson Spark）は、名前を出して読めないと伝える。
    func testFLVSorensonIsReportedByName() async throws {
        do {
            _ = try await convert("sorenson-mp3.flv")
            XCTFail("Sorenson Spark は読めないはず")
        } catch let EngineError.unsupported(message) {
            XCTAssertTrue(message.contains("Sorenson"), message)
        }
    }

    /// AVCHD と同じ M2TS（H.264・AC-3）。
    func testM2TSH264AndAC3() async throws {
        let result = try await convert("h264-ac3.m2ts")
        XCTAssertEqual(result.container, "M2TS")
        try await check(result, video: true, audio: result.notes.isEmpty)
    }

    /// MPEG-TS（HEVC・AAC の ADTS）。
    func testTSHEVCAndAAC() async throws {
        let result = try await convert("hevc-aac.ts")
        XCTAssertEqual(result.container, "MPEG-TS")
        XCTAssertTrue(result.notes.isEmpty, "\(result.notes)")
        try await check(result, video: true, audio: true)
    }

    /// MPEG-TS（MPEG-2・MP2）。MPEG-2 と MP2 は端末によって読めないことがあるので、そのときは何が読めないかを伝える。
    func testTSMPEG2AndMP2() async throws {
        do {
            let result = try await convert("mpeg2-mp2.ts")
            try await check(result, video: true, audio: result.notes.isEmpty)
            print("MPEG-2・MP2 の変換: 知らせ \(result.notes)")
        } catch let EngineError.unsupported(message) {
            XCTAssertTrue(message.contains("MPEG-2"), message)
            print("MPEG-2 はこの端末で読めない: \(message)")
        }
    }

    /// 取り込みの入口から：MP4 になり、素材として長さや大きさが入る。
    func testImportThroughMediaStore() async throws {
        let made: MediaStore.ConvertedImport = try await MediaStore.shared.importConverted(at: try fixture("h264-aac-srt.mkv"), progress: nil)
        XCTAssertEqual(made.asset.kind, .video)
        XCTAssertEqual(made.asset.width, 96)
        XCTAssertTrue(made.asset.hasAudio)
        XCTAssertTrue(made.asset.codec.contains("MKV"))
        XCTAssertEqual(made.subtitles.count, 2)
        XCTAssertNotNil(MediaStore.shared.url(for: made.asset))
    }
}
#endif
