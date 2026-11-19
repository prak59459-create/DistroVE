#if canImport(MetalKit) && canImport(AVFoundation)
import CoreImage
import XCTest
@testable import DistroKit

/// 3D（Q50）を Metal で実際に描くテスト（macOS で実行）。
final class Engine3DTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distrove-3d-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
    }

    override func tearDown() {
        AppPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let size = CGSize(width: 320, height: 180)

    /// 不透明な画素の割合・明るさの段階の数・平均の明るさ。
    private func coverage(_ image: CIImage) -> (opaque: Double, levels: Int, mean: Double) {
        let w: Int = Int(size.width)
        let h: Int = Int(size.height)
        var bitmap: [UInt8] = Array(repeating: 0, count: w * h * 4)
        let context = CIContext()
        context.render(image, toBitmap: &bitmap, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var opaque: Int = 0
        var levels: Set<Int> = []
        var sum: Int = 0
        for i in 0..<(w * h) where bitmap[i * 4 + 3] > 200 {
            opaque += 1
            let lum: Int = (Int(bitmap[i * 4]) + Int(bitmap[i * 4 + 1]) + Int(bitmap[i * 4 + 2])) / 3
            levels.insert(lum / 16)
            sum += lum
        }
        let mean: Double = opaque > 0 ? Double(sum) / Double(opaque) / 255 : 0
        return (Double(opaque) / Double(w * h), levels.count, mean)
    }

    func testRendersExtrudedText() throws {
        let renderer: Renderer3D = try XCTUnwrap(Renderer3D.shared)
        let content = Object3DContent(kind: .text, text: "AB")
        var pose = Renderer3D.Pose()
        pose.rotationY = 20
        let image: CIImage = try XCTUnwrap(renderer.render(content, pose: pose, size: size, model: nil))
        XCTAssertEqual(image.extent.width, size.width)
        XCTAssertEqual(image.extent.height, size.height)
        let c = coverage(image)
        XCTAssertGreaterThan(c.opaque, 0.01)
        XCTAssertLessThan(c.opaque, 0.6)
        XCTAssertGreaterThan(c.mean, 0.2)
        // 日本語（代わりのフォントの輪郭）も形になる
        let japanese = Object3DContent(kind: .text, text: "動画")
        let jp: CIImage = try XCTUnwrap(renderer.render(japanese, pose: Renderer3D.Pose(), size: size, model: nil))
        XCTAssertGreaterThan(coverage(jp).opaque, 0.01)
    }

    func testCubeFacesAreShadedDifferently() throws {
        let renderer: Renderer3D = try XCTUnwrap(Renderer3D.shared)
        var content = Object3DContent(kind: .cube)
        content.size = 0.6
        var pose = Renderer3D.Pose()
        pose.rotationX = 25
        pose.rotationY = 40
        let c = coverage(try XCTUnwrap(renderer.render(content, pose: pose, size: size, model: nil)))
        XCTAssertGreaterThan(c.opaque, 0.05)
        XCTAssertGreaterThanOrEqual(c.levels, 3)
    }

    func testLoadsAndRendersOBJModel() throws {
        let obj: String = """
        v -1 -1 -1
        v 1 -1 -1
        v 1 1 -1
        v -1 1 -1
        v -1 -1 1
        v 1 -1 1
        v 1 1 1
        v -1 1 1
        f 1 4 3 2
        f 5 6 7 8
        f 1 2 6 5
        f 2 3 7 6
        f 3 4 8 7
        f 4 1 5 8
        """
        let url: URL = root.appendingPathComponent("box.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        let model: Geometry3D.LoadedModel = try Geometry3D.loadModel(url: url)
        XCTAssertEqual(model.mesh.triangleCount, 12)
        let b = model.mesh.bounds
        XCTAssertEqual(Double(b.max.x - b.min.x), 1, accuracy: 0.001)
        let renderer: Renderer3D = try XCTUnwrap(Renderer3D.shared)
        var content = Object3DContent(kind: .model)
        content.motion = .none
        var pose = Renderer3D.Pose()
        pose.rotationY = 30
        let image: CIImage = try XCTUnwrap(renderer.render(content, pose: pose, size: size,
                                                           model: Renderer3D.ModelSource(key: "box", url: url)))
        XCTAssertGreaterThan(coverage(image).opaque, 0.03)
    }

    /// 編集の流れ（合成 → 1 枚の画像）を通しても 3D が描かれる。
    func testObject3DClipAppearsInComposition() async throws {
        var project = Project(name: "3d", canvas: CanvasSettings(aspect: .landscape16x9))
        var clip = Clip(kind: .object3D, name: "球", start: .zero, duration: Time(seconds: 2))
        var content = Object3DContent(kind: .sphere)
        content.size = 0.7
        clip.object3D = content
        project.placeOverlay(clip, at: .zero)
        let still: CGImage = try await Exporter().still(project: project, at: Time(seconds: 0.5), maxSide: 320)
        let w: Int = 32
        let h: Int = 18
        let gray: [UInt8] = VisionTools.grayscale(still, width: w, height: h)
        let center: Int = Int(gray[(h / 2) * w + w / 2])
        let corner: Int = Int(gray[1 * w + 1])
        XCTAssertGreaterThan(center, corner + 40)
    }
}
#endif
