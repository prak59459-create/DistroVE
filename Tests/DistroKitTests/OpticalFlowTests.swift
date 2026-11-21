import XCTest
@testable import DistroKit

/// 自前の動きの推定（Q99 の予備。Vision が使えない端末用）。
final class OpticalFlowTests: XCTestCase {
    /// 内容を (dx, dy) だけ動かした模様。scale で模様の細かさを絵の大きさに合わせる（大きい絵ほど模様も大きい）。
    private func pattern(width: Int, height: Int, dx: Float, dy: Float, scale: Float = 1) -> GrayImage {
        var pixels: [Float] = []
        pixels.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let sx: Float = (Float(x) - dx) / scale
                let sy: Float = (Float(y) - dy) / scale
                let v: Float = 128 + 60 * sin(sx / 5) * cos(sy / 7) + 40 * sin((sx + sy) / 11)
                pixels.append(v)
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }

    func testRecoversSmallShift() {
        let a: GrayImage = pattern(width: 160, height: 96, dx: 0, dy: 0)
        let b: GrayImage = pattern(width: 160, height: 96, dx: 5, dy: -3)
        let field: FlowField = OpticalFlowLK.flow(from: a, to: b)
        let mean: (dx: Float, dy: Float) = field.interiorMean
        XCTAssertEqual(Double(mean.dx), 5, accuracy: 0.5)
        XCTAssertEqual(Double(mean.dy), -3, accuracy: 0.5)
    }

    func testRecoversLargeShiftThroughPyramid() {
        let a: GrayImage = pattern(width: 256, height: 144, dx: 0, dy: 0)
        let b: GrayImage = pattern(width: 256, height: 144, dx: 14, dy: 6)
        let field: FlowField = OpticalFlowLK.flow(from: a, to: b)
        let mean: (dx: Float, dy: Float) = field.interiorMean
        XCTAssertEqual(Double(mean.dx), 14, accuracy: 1.5)
        XCTAssertEqual(Double(mean.dy), 6, accuracy: 1.5)
    }

    func testWorksAtReducedSizeForBigFrames() {
        let a: GrayImage = pattern(width: 640, height: 360, dx: 0, dy: 0, scale: 4)
        let b: GrayImage = pattern(width: 640, height: 360, dx: 8, dy: 0, scale: 4)
        let field: FlowField = OpticalFlowLK.flow(from: a, to: b)
        XCTAssertLessThanOrEqual(field.width, OpticalFlowLK.workingWidth)
        // 計算した大きさ（半分）での画素なので、動きも半分になる
        let mean: (dx: Float, dy: Float) = field.interiorMean
        XCTAssertEqual(Double(mean.dx) * 640 / Double(field.width), 8, accuracy: 1.2)
    }
}
