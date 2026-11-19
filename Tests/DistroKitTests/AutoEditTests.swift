import XCTest
@testable import DistroKit

final class AutoEditTests: XCTestCase {
    func asset(_ seconds: Double, _ kind: MediaKind = .video) -> MediaAsset {
        var a = MediaAsset(kind: kind, name: "a", storage: .copied)
        a.duration = kind == .image ? .zero : Time(seconds: seconds)
        a.width = 1920
        a.height = 1080
        return a
    }

    func testBeatSyncCutsOnBeats() {
        var p = Project(name: "b", canvas: CanvasSettings(aspect: .portrait9x16))
        let a = asset(10)
        let b = asset(10)
        p.media = [a, b]
        var beats: [Time] = []
        for i in 0..<17 { beats.append(Time(seconds: 0.5 * Double(i))) }
        let sources = [
            AutoEdit.Source(mediaID: a.id, name: "a", sourceStart: .zero, sourceDuration: a.duration, isStill: false, template: nil),
            AutoEdit.Source(mediaID: b.id, name: "b", sourceStart: .zero, sourceDuration: b.duration, isStill: false, template: nil)
        ]
        let count = AutoEdit.beatSync(project: &p, sources: sources, beats: beats, beatsPerCut: 2,
                                      transition: ClipTransition(kind: .flashWhite, duration: Time(seconds: 0.2)), effects: [.shake])
        XCTAssertEqual(count, 8)
        let clips = p.tracks[0].clips
        XCTAssertEqual(clips[0].mediaID, a.id)
        XCTAssertEqual(clips[1].mediaID, b.id)
        XCTAssertEqual(clips[2].sourceStart, Time(seconds: 1))
        for c in clips { XCTAssertEqual(c.duration, Time(seconds: 1)) }
        XCTAssertNil(clips[0].transitionIn)
        XCTAssertEqual(clips[1].transitionIn?.kind, .flashWhite)
        XCTAssertTrue(clips[0].effects[0].beatSync)
    }

    func testCutSilences() {
        var p = Project(name: "s", canvas: CanvasSettings(aspect: .landscape16x9))
        let a = asset(10)
        p.media = [a]
        p.appendToMain(p.makeClip(for: a))
        let id = p.tracks[0].clips[0].id
        let removed = AutoEdit.cutSilences(project: &p, clipID: id, silences: [2...3, 6...8])
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(p.tracks[0].clips.count, 3)
        XCTAssertEqual(p.duration, Time(seconds: 7))
        XCTAssertEqual(p.tracks[0].clips[1].sourceStart, Time(seconds: 3))
        XCTAssertEqual(p.tracks[0].clips[2].sourceStart, Time(seconds: 8))
    }

    func testConvertToShort() {
        var p = Project(name: "s", canvas: CanvasSettings(aspect: .landscape16x9))
        let a = asset(90)
        p.media = [a]
        p.appendToMain(p.makeClip(for: a))
        AutoEdit.convertToShort(project: &p, maxDuration: Time(seconds: 60), subjectX: [a.id: 0.8])
        XCTAssertEqual(p.canvas.width, 1080)
        XCTAssertEqual(p.canvas.height, 1920)
        XCTAssertEqual(p.duration, Time(seconds: 60))
        XCTAssertEqual(p.tracks[0].clips[0].fitMode, .fill)
        // 被写体が右寄りなので左にずらす
        XCTAssertLessThan(p.tracks[0].clips[0].transform.positionX.value, 0)
        XCTAssertEqual(AutoEdit.reframeOffset(sourceAspect: 0.5, canvasAspect: 0.5625, subjectX: 0.9), 0)
    }

    func testBuildCues() {
        let words = [
            AutoEdit.Word(text: "今日は", start: 0, duration: 0.4),
            AutoEdit.Word(text: "いい", start: 0.4, duration: 0.3),
            AutoEdit.Word(text: "天気です。", start: 0.7, duration: 0.6),
            AutoEdit.Word(text: "散歩に", start: 2.5, duration: 0.4),
            AutoEdit.Word(text: "行きます", start: 2.9, duration: 0.5)
        ]
        let cues = AutoEdit.buildCues(words: words, offset: Time(seconds: 10))
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "今日はいい天気です。")
        XCTAssertEqual(cues[0].start, Time(seconds: 10))
        XCTAssertEqual(cues[1].text, "散歩に行きます")
        let english = AutoEdit.buildCues(words: [AutoEdit.Word(text: "hello", start: 0, duration: 0.3), AutoEdit.Word(text: "world", start: 0.3, duration: 0.3)])
        XCTAssertEqual(english.first?.text, "hello world")
    }

    func testTemplates() {
        let templates = TemplateLibrary.builtin()
        XCTAssertEqual(templates.count, 8)
        let phonk = templates.first { $0.id == "phonk-edit" }!
        var music = MediaAsset(kind: .audio, name: "bgm", storage: .generated)
        music.duration = Time(seconds: 8)
        var beats: [Time] = []
        for i in 0..<16 { beats.append(Time(seconds: Double(i) * 60 / 130)) }
        let p = TemplateLibrary.makeProject(phonk, media: [asset(20), asset(0, .image)], music: music, beats: beats)
        XCTAssertEqual(p.canvas.aspect, .portrait9x16)
        XCTAssertGreaterThan(p.tracks[0].clips.count, 4)
        XCTAssertEqual(p.beatTimes.count, 16)
        XCTAssertFalse(p.trackIndices(of: .audio).isEmpty)
        XCTAssertEqual(p.tracks[0].clips[0].look?.builtinName, "phonkDark")
        let education = templates.first { $0.id == "education" }!
        let e = TemplateLibrary.makeProject(education, media: [asset(30), asset(30)], music: nil, beats: [])
        XCTAssertEqual(e.tracks[0].clips.count, 4)
        XCTAssertEqual(e.tracks[0].clips[0].duration, Time(seconds: 6))
        XCTAssertFalse(e.trackIndices(of: .subtitle).isEmpty)
    }

    func testSoundLibrary() {
        for sound in SoundLibrary.all {
            let samples = SoundLibrary.render(sound.id)
            XCTAssertNotNil(samples, sound.id)
            let s = samples!
            XCTAssertGreaterThan(s.count, 1000, sound.id)
            var peak: Float = 0
            for v in s {
                XCTAssertTrue(v.isFinite, sound.id)
                peak = max(peak, abs(v))
            }
            XCTAssertGreaterThan(peak, 0.3, sound.id)
            XCTAssertLessThanOrEqual(peak, 1.0, sound.id)
        }
        let wav = SoundLibrary.wav([0, 0.5, -0.5], sampleRate: 22_050)
        XCTAssertEqual(wav.count, 44 + 6)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
    }

    func testSoundBeatsMatchBPM() throws {
        let samples = try XCTUnwrap(SoundLibrary.render("bgm.drums"))
        let features = AudioFeatureExtractor.extract(samples: samples, sampleRate: SoundLibrary.sampleRate)
        let result = try XCTUnwrap(BeatDetector.analyze(features))
        let ratio = result.bpm / 100
        // 100BPM のドラム。倍・半分のテンポに取られることはあるが、拍の周期は合っている
        let close = abs(ratio - 1) < 0.04 || abs(ratio - 2) < 0.08 || abs(ratio - 0.5) < 0.03
        XCTAssertTrue(close, "bpm \(result.bpm)")
    }
}
