import XCTest
@testable import DistroKit

final class BasicsTests: XCTestCase {
    func testFrameDurations() {
        XCTAssertEqual(Time.frameDuration(fps: 30).ticks, 2000)
        XCTAssertEqual(Time.frameDuration(fps: 24).ticks, 2500)
        XCTAssertEqual(Time.frameDuration(fps: 60).ticks, 1000)
        XCTAssertEqual(Time.frameDuration(fps: 120).ticks, 500)
        XCTAssertEqual(Time.frameDuration(fps: 29.97).ticks, 2002)
        XCTAssertEqual(Time.frameDuration(fps: 59.94).ticks, 1001)
    }

    func testTimecodeAndSnapping() {
        let t = Time(seconds: 65.5)
        XCTAssertEqual(t.timecode(fps: 30), "01:05.15")
        XCTAssertEqual(Time(seconds: 3725).timecode(fps: 30), "1:02:05.00")
        XCTAssertEqual(Time(seconds: 1.01).snappedToFrame(fps: 30), Time(seconds: 1.0))
        XCTAssertEqual(Time(seconds: 2.0).frameIndex(fps: 24), 48)
        XCTAssertEqual(Time(seconds: 75).shortLabel, "1:15")
    }

    func testTimeRange() {
        let a = TimeRange(start: Time(seconds: 1), duration: Time(seconds: 2))
        let b = TimeRange(start: Time(seconds: 2.5), duration: Time(seconds: 2))
        XCTAssertTrue(a.overlaps(b))
        XCTAssertEqual(a.intersection(b), TimeRange(start: Time(seconds: 2.5), end: Time(seconds: 3)))
        XCTAssertFalse(a.contains(Time(seconds: 3)))
    }

    func testColorHex() {
        let c = RGBA(hex: "#FF8000")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.hex, "#FF8000")
        XCTAssertEqual(RGBA(1, 0, 0, 0.5).hex, "#FF000080")
        XCTAssertNil(RGBA(hex: "xyz"))
    }

    func testParamInterpolation() {
        var p = Param(0)
        let tol = Time(seconds: 0.01)
        p.toggleKey(at: .zero, tolerance: tol)
        p.toggleKey(at: Time(seconds: 2), tolerance: tol)
        p.set(10, at: Time(seconds: 2), tolerance: tol)
        p.keys[0].easing = .linear
        XCTAssertEqual(p.value(at: Time(seconds: 1)), 5, accuracy: 0.0001)
        XCTAssertEqual(p.value(at: Time(seconds: -1)), 0)
        XCTAssertEqual(p.value(at: Time(seconds: 5)), 10)
        p.keys[0].easing = .hold
        XCTAssertEqual(p.value(at: Time(seconds: 1.9)), 0)
        p.keys[0].easing = .easeInOut
        XCTAssertEqual(p.value(at: Time(seconds: 1)), 5, accuracy: 0.0001)
        // 分割しても境目の値が保たれる
        let parts = p.split(at: Time(seconds: 0.5))
        XCTAssertEqual(parts.0.value(at: Time(seconds: 0.5)), p.value(at: Time(seconds: 0.5)), accuracy: 0.0001)
        XCTAssertEqual(parts.1.value(at: .zero), p.value(at: Time(seconds: 0.5)), accuracy: 0.0001)
        XCTAssertEqual(parts.1.value(at: Time(seconds: 1.5)), 10, accuracy: 0.0001)
    }

    func testParamCompactCoding() throws {
        let plain = Param(0.5)
        let data = try JSONEncoder().encode(plain)
        XCTAssertEqual(String(data: data, encoding: .utf8), "0.5")
        var keyed = Param(1)
        keyed.toggleKey(at: .zero, tolerance: .zero)
        let keyedData = try JSONEncoder().encode(keyed)
        let decoded = try JSONDecoder().decode(Param.self, from: keyedData)
        XCTAssertEqual(decoded, keyed)
        XCTAssertEqual(try JSONDecoder().decode(Param.self, from: data), plain)
    }

    func testEasingEndpoints() {
        for easing in Easing.allCases where easing != .hold {
            XCTAssertEqual(easing.apply(0), 0, accuracy: 0.0001)
            XCTAssertEqual(easing.apply(1), 1, accuracy: 0.0001)
        }
    }

    func testSpeedMap() {
        let constant = SpeedMap(settings: SpeedSettings(rate: 2))
        XCTAssertEqual(constant.sourceDuration(forTimeline: Time(seconds: 3)), Time(seconds: 6))
        XCTAssertEqual(constant.timelineDuration(forSource: Time(seconds: 6)), Time(seconds: 3))
        var curved = SpeedSettings()
        curved.curve = [SpeedPoint(0, 1), SpeedPoint(1, 3)]
        let map = SpeedMap(settings: curved)
        XCTAssertEqual(map.meanRate, 2, accuracy: 0.0001)
        let segments = map.segments(timelineDuration: Time(seconds: 2))
        var timeline: Int64 = 0
        var source: Int64 = 0
        for s in segments {
            XCTAssertEqual(s.timelineOffset.ticks, timeline)
            XCTAssertEqual(s.sourceOffset.ticks, source)
            timeline += s.timelineDuration.ticks
            source += s.sourceDuration.ticks
        }
        XCTAssertEqual(timeline, Time(seconds: 2).ticks)
        XCTAssertEqual(Double(source), Double(Time(seconds: 4).ticks), accuracy: 2)
    }
}
