#if canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import DistroKit

/// 話者の自動判別（Q57）を、タイムラインの音から通しで確かめる（macOS で実行）。
final class SpeakerDetectionTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distrove-speakers-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
    }

    override func tearDown() {
        AppPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// 倍音つきの音（低くこもった声と、高く明るい声）。
    private func voice(_ low: Bool, frames: Int, rate: Double, into channel: UnsafeMutablePointer<Float>, at offset: Int) {
        let pitch: Double = low ? 115 : 230
        let brightness: Double = low ? 0.5 : 0.85
        for i in 0..<frames {
            let t: Double = Double(i) / rate
            var v: Double = 0
            for h in 1...12 {
                let weight: Double = pow(brightness, Double(h - 1)) / Double(h)
                v += weight * sin(2 * Double.pi * pitch * Double(h) * t)
            }
            channel[offset + i] = Float(0.2 * v)
        }
    }

    func testCuesAreSplitBetweenTwoVoices() async throws {
        // 1 秒ずつ「低・高・低・低・高」と話す 5 秒の音（44.1kHz。読むときに 16kHz に直る）
        let pattern: [Bool] = [true, false, true, true, false]
        let rate: Double = 44_100
        let perCue: Int = Int(rate)
        let total: Int = perCue * pattern.count
        let url: URL = root.appendingPathComponent("talk.wav")
        let format: AVAudioFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let buffer: AVAudioPCMBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)))
        buffer.frameLength = AVAudioFrameCount(total)
        let channel: UnsafeMutablePointer<Float> = try XCTUnwrap(buffer.floatChannelData?[0])
        for (index, low) in pattern.enumerated() {
            voice(low, frames: perCue, rate: rate, into: channel, at: index * perCue)
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }

        let asset: MediaAsset = try await MediaStore.shared.importFile(at: url, copy: true)
        XCTAssertEqual(asset.kind, .audio)
        var project = Project(name: "speakers", canvas: CanvasSettings(aspect: .landscape16x9, shortSide: 360, fps: 30))
        project.media.append(asset)
        project.placeAudio(project.makeClip(for: asset), at: .zero)
        var cues: [SubtitleCue] = []
        for index in 0..<pattern.count {
            let start: Double = Double(index) + 0.1
            cues.append(SubtitleCue(start: Time(seconds: start), end: Time(seconds: start + 0.8), text: "字幕 \(index + 1)"))
        }
        project.setCues(cues, replace: true)

        let result: [UUID: Int] = try await SpeakerDetector.assign(project: project, speakers: nil)
        XCTAssertEqual(result.count, pattern.count)
        let labels: [Int] = cues.map { result[$0.id] ?? -1 }
        XCTAssertEqual(labels, [0, 1, 0, 0, 1])
        // 人数を決めて分けても同じ
        let fixed: [UUID: Int] = try await SpeakerDetector.assign(project: project, speakers: 2)
        XCTAssertEqual(cues.map { fixed[$0.id] ?? -1 }, [0, 1, 0, 0, 1])
    }

    /// 長い字幕は真ん中の数秒だけを調べる区間にする。
    func testWindowsUseTheMiddleOfLongCues() {
        var project = Project(name: "windows", canvas: CanvasSettings(aspect: .landscape16x9, shortSide: 360, fps: 30))
        let long = SubtitleCue(start: Time(seconds: 10), end: Time(seconds: 30), text: "長い")
        let short = SubtitleCue(start: Time(seconds: 2), end: Time(seconds: 3), text: "短い")
        let tiny = SubtitleCue(start: Time(seconds: 5), end: Time(seconds: 5.02), text: "とても短い")
        project.setCues([long, short, tiny], replace: true)
        let windows: [SpeakerDetector.Window] = SpeakerDetector.windows(project)
        XCTAssertEqual(windows.map { $0.id }, [short.id, long.id], "始まりの順。短すぎる字幕は調べない")
        let rate: Double = SpeakerDetector.sampleRate
        XCTAssertEqual(windows[0].start, Int(2 * rate))
        XCTAssertEqual(windows[0].end, Int(3 * rate))
        XCTAssertEqual(windows[1].start, Int(18 * rate))
        XCTAssertEqual(windows[1].end, Int(22 * rate))
    }
}
#endif
