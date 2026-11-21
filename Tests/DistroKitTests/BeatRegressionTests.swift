import XCTest
@testable import DistroKit

/// 内蔵 BGM（シンコペーションのある phonk など）でテンポを取り違えないことを確かめる。
final class BeatRegressionTests: XCTestCase {
    func bpm(_ id: String) throws -> Double {
        let samples = try XCTUnwrap(SoundLibrary.render(id))
        let features = AudioFeatureExtractor.extract(samples: samples, sampleRate: SoundLibrary.sampleRate)
        return try XCTUnwrap(BeatDetector.analyze(features)).bpm
    }

    func testBuiltinTempos() throws {
        let expected: [String: Double] = ["bgm.phonk": 130, "bgm.upbeat": 120, "bgm.lofi": 85, "bgm.drums": 100]
        for (id, tempo) in expected {
            let found = try bpm(id)
            print("\(id): \(found)")
            let ratio = found / tempo
            let ok = abs(ratio - 1) < 0.04 || abs(ratio - 2) < 0.08 || abs(ratio - 0.5) < 0.02
            XCTAssertTrue(ok, "\(id) expected \(tempo) got \(found)")
        }
    }
}
