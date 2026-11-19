import XCTest
@testable import DistroKit

final class FormatsTests: XCTestCase {
    func testProjectRoundTrip() throws {
        var p = Project(name: "往復", canvas: CanvasSettings(aspect: .portrait9x16, fps: 60))
        var asset = MediaAsset(kind: .video, name: "clip.mov", storage: .copied)
        asset.duration = Time(seconds: 5)
        asset.relativePath = "media/clip.mov"
        p.media.append(asset)
        var clip = p.makeClip(for: asset)
        clip.effects.append(VideoEffect(kind: .glitch))
        clip.transitionIn = ClipTransition(kind: .cube3D)
        clip.look = LookSettings(id: "builtin:film")
        clip.curves = CurveSet.sCurve(0.1)
        clip.transform.rotation.toggleKey(at: .zero, tolerance: .zero)
        p.appendToMain(clip)
        p.setCues([SubtitleCue(start: .zero, end: Time(seconds: 1), text: "こんにちは")], replace: true)
        p.setBeatMarkers([Time(seconds: 0.5), Time(seconds: 1)])
        let data = try ProjectFile.encode(p)
        let loaded = try ProjectFile.decode(data)
        XCTAssertEqual(loaded.id, p.id)
        XCTAssertEqual(loaded.canvas, p.canvas)
        XCTAssertEqual(loaded.tracks.count, p.tracks.count)
        XCTAssertEqual(loaded.tracks[0].clips[0].effects.first?.kind, .glitch)
        XCTAssertEqual(loaded.tracks[0].clips[0].transitionIn?.kind, .cube3D)
        XCTAssertEqual(loaded.tracks[0].clips[0].transform.rotation.keys.count, 1)
        XCTAssertEqual(loaded.tracks.last?.cues.first?.text, "こんにちは")
        XCTAssertEqual(loaded.beatTimes.count, 2)
    }

    func testDecodeMinimalAndFutureFields() throws {
        let id = UUID().uuidString
        let clipID = UUID().uuidString
        let trackID = UUID().uuidString
        let json = """
        {"id":"\(id)","name":"最小","futureField":123,
         "tracks":[{"id":"\(trackID)","kind":"video","clips":[{"id":"\(clipID)","kind":"text","start":0,"duration":60000,"unknown":true}]}]}
        """
        let p = try ProjectFile.decode(Data(json.utf8))
        XCTAssertEqual(p.name, "最小")
        XCTAssertEqual(p.tracks[0].clips.count, 1)
        XCTAssertEqual(p.tracks[0].clips[0].duration, Time(seconds: 1))
        XCTAssertEqual(p.tracks[0].clips[0].transform.scale.value, 1)
        XCTAssertTrue(p.magneticMainTrack)
    }

    func testNewerFormatIsRejected() throws {
        var p = Project(name: "x", canvas: CanvasSettings(aspect: .square1x1))
        p.formatVersion = 99
        let data = try ProjectFile.encode(p)
        XCTAssertThrowsError(try ProjectFile.decode(data))
    }

    func testSRTParseAndExport() {
        let text = "\u{FEFF}1\r\n00:00:01,000 --> 00:00:02,500\r\n<i>こんにちは</i>\r\n世界\r\n\r\n2\r\n00:00:03.000 --> 00:00:04.000 align:start\r\nふたつめ\r\n"
        let cues = SRT.parse(text)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "こんにちは\n世界")
        XCTAssertEqual(cues[0].start, Time(seconds: 1))
        XCTAssertEqual(cues[0].end, Time(seconds: 2.5))
        XCTAssertEqual(cues[1].start, Time(seconds: 3))
        let exported = SRT.export(cues)
        XCTAssertTrue(exported.hasPrefix("1\n00:00:01,000 --> 00:00:02,500\n"))
        XCTAssertEqual(SRT.parse(exported).count, 2)
        XCTAssertTrue(SRT.exportVTT(cues).hasPrefix("WEBVTT"))
        XCTAssertEqual(SRT.timestamp(Time(seconds: 3723.456)), "01:02:03,456")
    }

    func testCubeParseAndSample() throws {
        var text = "TITLE \"test\"\nLUT_3D_SIZE 2\n"
        // 赤が一番速く変わる順。色を反転する LUT
        for b in 0..<2 {
            for g in 0..<2 {
                for r in 0..<2 {
                    text += "\(1 - r) \(1 - g) \(1 - b)\n"
                }
            }
        }
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.title, "test")
        let c = lut.sample(0.25, 0.5, 1)
        XCTAssertEqual(c.0, 0.75, accuracy: 0.0001)
        XCTAssertEqual(c.1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(c.2, 0, accuracy: 0.0001)
        let reparsed = try CubeLUT.parse(lut.cubeText())
        XCTAssertEqual(reparsed.data.count, lut.data.count)
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 3\n0 0 0\n"))
    }

    func test1DLutAndCurves() throws {
        let text = "LUT_1D_SIZE 2\n0 0 0\n0.5 0.5 0.5\n"
        let lut = try CubeLUT.parse(text)
        let c = lut.sample(1, 1, 1)
        XCTAssertEqual(c.0, 0.5, accuracy: 0.01)
        let curve = ToneCurve.table([Vec2(0, 0), Vec2(0.5, 0.7), Vec2(1, 1)])
        XCTAssertEqual(curve.count, 256)
        XCTAssertEqual(curve[0], 0, accuracy: 0.001)
        XCTAssertEqual(curve[255], 1, accuracy: 0.001)
        XCTAssertEqual(curve[128], 0.7, accuracy: 0.02)
        // 単調増加
        for i in 1..<curve.count { XCTAssertGreaterThanOrEqual(curve[i] + 0.0001, curve[i - 1]) }
        let combined = CubeLUT.combined(lut: nil, curves: CurveSet.sCurve(0.1), size: 9)
        XCTAssertEqual(combined.size, 9)
    }

    func testBuiltinLooks() {
        for look in BuiltinLooks.all {
            let lut = BuiltinLooks.lut(named: look.id, size: 9)
            XCTAssertNotNil(lut, look.id)
            for v in lut!.data { XCTAssertTrue(v >= 0 && v <= 1, look.id) }
        }
        let mono = BuiltinLooks.lut(named: "mono", size: 9)!
        let c = mono.sample(1, 0, 0)
        XCTAssertEqual(c.0, c.1, accuracy: 0.001)
        XCTAssertNil(BuiltinLooks.lut(named: "nothing"))
    }

    func testExportSizes() {
        var s = ExportSettings()
        s.resolution = .p1080
        XCTAssertTrue(s.outputSize(canvasWidth: 1080, canvasHeight: 1920) == (1080, 1920))
        XCTAssertTrue(s.outputSize(canvasWidth: 1920, canvasHeight: 1080) == (1920, 1080))
        s.resolution = .p2160
        XCTAssertTrue(s.outputSize(canvasWidth: 1920, canvasHeight: 1080) == (3840, 2160))
        s.resolution = .p480
        let w = s.outputSize(canvasWidth: 1920, canvasHeight: 1080).width
        XCTAssertEqual(w % 2, 0)
        XCTAssertGreaterThan(s.effectiveBitrate(width: 1920, height: 1080), 1_000_000)
        let limits = DeviceLimits(maxResolution: .p1080, maxFps: 60, supportsHEVC: false)
        var big = ExportSettings()
        big.resolution = .p2160
        big.fps = 120
        big.codec = .hevc
        let clamped = limits.clamp(big)
        XCTAssertEqual(clamped.resolution, .p1080)
        XCTAssertEqual(clamped.fps, 60)
        XCTAssertEqual(clamped.codec, .h264)
        XCTAssertTrue(AspectPreset.portrait9x16.size(shortSide: 1080) == (1080, 1920))
    }

    func testContentManifestDiff() {
        let a = ContentManifest.File(path: "templates/a.json", sha256: "aa", size: 1, kind: "template")
        let b = ContentManifest.File(path: "luts/b.cube", sha256: "bb", size: 1, kind: "lut")
        let b2 = ContentManifest.File(path: "luts/b.cube", sha256: "BB2", size: 1, kind: "lut")
        let evil = ContentManifest.File(path: "../../etc/x", sha256: "cc", size: 1, kind: "lut")
        let local = ContentManifest(version: 1, minimumAppVersion: nil, files: [a, b])
        let remote = ContentManifest(version: 2, minimumAppVersion: "0.1.0", files: [b2, evil])
        let diff = ContentManifest.diff(local: local, remote: remote)
        XCTAssertEqual(diff.download, [b2])
        XCTAssertEqual(diff.remove, ["templates/a.json"])
        XCTAssertTrue(ContentManifest.isCompatible(appVersion: "0.1.0", minimum: "0.1.0"))
        XCTAssertTrue(ContentManifest.isCompatible(appVersion: "0.10.0", minimum: "0.9.5"))
        XCTAssertFalse(ContentManifest.isCompatible(appVersion: "0.1.0", minimum: "1.0"))
        XCTAssertFalse(ContentManifest.isSafePath("/abs"))
        XCTAssertFalse(ContentManifest.isSafePath("other/x"))
    }

    func testMediaFormatSupport() {
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "MOV"), .video)
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "gif"), .gif)
        XCTAssertNotNil(MediaFormatSupport.unsupportedReason(forExtension: "mkv"))
        XCTAssertNil(MediaFormatSupport.unsupportedReason(forExtension: "mp4"))
    }
}
