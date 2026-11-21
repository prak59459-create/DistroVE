import XCTest
@testable import DistroKit

/// 端末の性能（Q81）・編集の経験（Q15）・ツールバーの並び（Q70）・なめらかスローの設定（Q99）。
final class AdaptivityTests: XCTestCase {
    func testDeviceTierClassification() {
        // iPad（第 9 世代）A13・3GB
        XCTAssertEqual(DeviceTier.classify(memoryGB: 3, cores: 6, modernGPU: false), .light)
        // iPad（第 10 世代）A14・4GB
        XCTAssertEqual(DeviceTier.classify(memoryGB: 4, cores: 6, modernGPU: true), .standard)
        // iPad Air / Pro（M1 以降）8GB
        XCTAssertEqual(DeviceTier.classify(memoryGB: 8, cores: 8, modernGPU: true), .high)
        XCTAssertEqual(DeviceTier.classify(memoryGB: 16, cores: 10, modernGPU: true), .high)
    }

    func testProxyThresholdFollowsTier() {
        var hd = MediaAsset(kind: .video, name: "hd", storage: .copied)
        hd.width = 1920
        hd.height = 1080
        hd.frameRate = 30
        XCTAssertTrue(hd.recommendsProxy(on: .light))
        XCTAssertFalse(hd.recommendsProxy(on: .standard))
        var uhd: MediaAsset = hd
        uhd.width = 3840
        uhd.height = 2160
        XCTAssertTrue(uhd.recommendsProxy(on: .standard))
        XCTAssertFalse(uhd.recommendsProxy(on: .high))
        XCTAssertEqual(DeviceTier.light.profile.previewScale, 0.5)
        XCTAssertLessThan(DeviceTier.light.profile.flowAccuracy, DeviceTier.high.profile.flowAccuracy)
    }

    func testRootToolsFollowOrderHiddenAndLevel() {
        let saved: [String] = ["ai", "media", "unknown", "ai"]
        let ordered: [RootTool] = RootTool.ordered(saved)
        XCTAssertEqual(ordered.first, .ai)
        XCTAssertEqual(ordered[1], .media)
        XCTAssertEqual(ordered.count, RootTool.allCases.count)
        let beginner: [RootTool] = RootTool.visible(order: saved, hidden: ["subtitles"], level: .beginner)
        XCTAssertFalse(beginner.contains(.object3D))
        XCTAssertFalse(beginner.contains(.subtitles))
        XCTAssertTrue(beginner.contains(.media))
        let pro: [RootTool] = RootTool.visible(order: saved, hidden: [], level: .pro)
        XCTAssertEqual(pro.count, RootTool.allCases.count)
        XCTAssertTrue(EditorLevel.beginner < EditorLevel.pro)
    }

    func testInterpolationSettingsAndOldFiles() throws {
        // 以前の「なめらかスロー」は光学フローとして読む
        let old: SpeedSettings = try JSONDecoder().decode(SpeedSettings.self, from: Data("{\"rate\":0.5,\"smooth\":true}".utf8))
        XCTAssertEqual(old.interpolation, .opticalFlow)
        XCTAssertTrue(old.smooth)
        XCTAssertEqual(old.motionBlur, 0)
        let plain: SpeedSettings = try JSONDecoder().decode(SpeedSettings.self, from: Data("{\"rate\":0.5}".utf8))
        XCTAssertEqual(plain.interpolation, .sampling)
        XCTAssertFalse(plain.makesFrames)
        var curve = SpeedSettings()
        curve.curve = [SpeedPoint(0, 1), SpeedPoint(0.5, 0.2), SpeedPoint(1, 1)]
        XCTAssertEqual(curve.slowestRate, 0.2, accuracy: 1e-9)
        curve.interpolation = .blending
        curve.motionBlur = 0.5
        let decoded: SpeedSettings = try JSONDecoder().decode(SpeedSettings.self, from: try JSONEncoder().encode(curve))
        XCTAssertEqual(decoded, curve)
        XCTAssertTrue(decoded.makesFrames)
        // 以前の素材の記録（interpolated）があっても読める
        let asset = MediaAsset(kind: .video, name: "v", storage: .copied)
        var json: [String: Any] = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(asset)) as? [String: Any])
        json["interpolated"] = ["path": "Interpolated/a.mov", "factor": 4]
        let again: MediaAsset = try JSONDecoder().decode(MediaAsset.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(again.id, asset.id)
    }
}

/// タイムラインの読み上げ（Q69）。
final class TimelineAccessibilityTests: XCTestCase {
    func testClipDescription() {
        var clip = Clip(kind: .video, name: "海", start: Time(seconds: 65), duration: Time(seconds: 3.5))
        clip.speed.rate = 2
        let track = Track(kind: .video, name: "映像 1")
        let text: (label: String, value: String) = TimelineAccessibility.describe(clip, track: track)
        XCTAssertEqual(text.label, "動画：海")
        XCTAssertEqual(text.value, "1:05 から 3.5 秒、2x")
        XCTAssertEqual(TimelineAccessibility.length(Time(seconds: 125)), "2 分 5 秒")
        XCTAssertEqual(TimelineAccessibility.length(Time(seconds: 4)), "4 秒")
    }
}
