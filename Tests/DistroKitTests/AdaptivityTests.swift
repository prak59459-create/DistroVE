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

    func testSmoothSlowMotionSettings() throws {
        let old: SpeedSettings = try JSONDecoder().decode(SpeedSettings.self, from: Data("{\"rate\":0.5}".utf8))
        XCTAssertFalse(old.smooth)
        XCTAssertEqual(old.suggestedInterpolationFactor, 4)
        var curve = SpeedSettings()
        curve.curve = [SpeedPoint(0, 1), SpeedPoint(0.5, 0.2), SpeedPoint(1, 1)]
        XCTAssertEqual(curve.slowestRate, 0.2, accuracy: 1e-9)
        XCTAssertEqual(curve.suggestedInterpolationFactor, 8)
        XCTAssertEqual(SpeedSettings(rate: 0.9).suggestedInterpolationFactor, 2)

        let made = InterpolatedMedia(path: "Interpolated/a.mov", factor: 4, range: TimeRange(start: Time(seconds: 1), duration: Time(seconds: 3)))
        XCTAssertTrue(made.covers(TimeRange(start: Time(seconds: 1.5), duration: Time(seconds: 2)), factor: 4))
        XCTAssertFalse(made.covers(TimeRange(start: Time(seconds: 0.5), duration: Time(seconds: 2)), factor: 4))
        XCTAssertFalse(made.covers(TimeRange(start: Time(seconds: 1.5), duration: Time(seconds: 2)), factor: 8))
        var asset = MediaAsset(kind: .video, name: "v", storage: .copied)
        asset.interpolated = made
        let decoded: MediaAsset = try JSONDecoder().decode(MediaAsset.self, from: try JSONEncoder().encode(asset))
        XCTAssertEqual(decoded.interpolated, made)
    }
}
