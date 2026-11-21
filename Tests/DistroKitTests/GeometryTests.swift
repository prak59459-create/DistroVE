import XCTest
@testable import DistroKit

/// 3D（Q50）の形づくり：三角形分割・押し出し・基本の立体。
final class GeometryTests: XCTestCase {
    private func square(_ x: Double, _ y: Double, _ size: Double) -> [SIMD2<Double>] {
        return [SIMD2<Double>(x, y), SIMD2<Double>(x + size, y), SIMD2<Double>(x + size, y + size), SIMD2<Double>(x, y + size)]
    }

    private func triangleArea(_ points: [SIMD2<Double>], _ indices: [Int]) -> Double {
        var total: Double = 0
        var k: Int = 0
        while k + 2 < indices.count {
            total += abs(Extrusion.cross(points[indices[k]], points[indices[k + 1]], points[indices[k + 2]])) / 2
            k += 3
        }
        return total
    }

    /// 閉じた立体の体積（外向きの面なら正になる）。
    private func signedVolume(_ mesh: MeshData) -> Double {
        var total: Double = 0
        var k: Int = 0
        while k + 2 < mesh.indices.count {
            let a: SIMD3<Float> = mesh.positions[Int(mesh.indices[k])]
            let b: SIMD3<Float> = mesh.positions[Int(mesh.indices[k + 1])]
            let c: SIMD3<Float> = mesh.positions[Int(mesh.indices[k + 2])]
            let cross = SIMD3<Double>(Double(b.y * c.z - b.z * c.y), Double(b.z * c.x - b.x * c.z), Double(b.x * c.y - b.y * c.x))
            total += (Double(a.x) * cross.x + Double(a.y) * cross.y + Double(a.z) * cross.z) / 6
            k += 3
        }
        return total
    }

    /// 三角形の向き（頂点の並び）が法線と同じ側を向いている割合。
    private func windingAgreement(_ mesh: MeshData) -> Double {
        var agree: Int = 0
        var counted: Int = 0
        var k: Int = 0
        while k + 2 < mesh.indices.count {
            let ia: Int = Int(mesh.indices[k])
            let ib: Int = Int(mesh.indices[k + 1])
            let ic: Int = Int(mesh.indices[k + 2])
            let e1: SIMD3<Float> = mesh.positions[ib] - mesh.positions[ia]
            let e2: SIMD3<Float> = mesh.positions[ic] - mesh.positions[ia]
            let face = SIMD3<Float>(e1.y * e2.z - e1.z * e2.y, e1.z * e2.x - e1.x * e2.z, e1.x * e2.y - e1.y * e2.x)
            let length: Float = (face.x * face.x + face.y * face.y + face.z * face.z).squareRoot()
            k += 3
            if length < 1e-9 { continue }
            let n: SIMD3<Float> = mesh.normals[ia] + mesh.normals[ib] + mesh.normals[ic]
            counted += 1
            if face.x * n.x + face.y * n.y + face.z * n.z > 0 { agree += 1 }
        }
        return counted == 0 ? 0 : Double(agree) / Double(counted)
    }

    func testTriangulateSquareWithHole() {
        let result = Earcut.triangulate(outer: square(0, 0, 4), holes: [square(1, 1, 2).reversed()])
        XCTAssertEqual(result.indices.count % 3, 0)
        XCTAssertTrue(result.indices.allSatisfy { $0 >= 0 && $0 < result.points.count })
        XCTAssertEqual(triangleArea(result.points, result.indices), 12, accuracy: 1e-9)
    }

    func testTriangulateConcaveAndClockwise() {
        // L 字（時計回りで与えても埋められる）
        let l: [SIMD2<Double>] = [SIMD2<Double>(0, 0), SIMD2<Double>(0, 2), SIMD2<Double>(1, 2), SIMD2<Double>(1, 1),
                                  SIMD2<Double>(2, 1), SIMD2<Double>(2, 0)]
        let result = Earcut.triangulate(outer: l, holes: [])
        XCTAssertEqual(result.indices.count, 12)
        XCTAssertEqual(triangleArea(result.points, result.indices), 3, accuracy: 1e-9)
    }

    func testShapesSeparateOutersAndHoles() {
        // 「回」のような形：外側・穴・穴の中の島
        let contours: [[SIMD2<Double>]] = [square(0, 0, 10), square(2, 2, 6), square(4, 4, 2), square(20, 0, 3)]
        let shapes: [Extrusion.Shape] = Extrusion.shapes(from: contours)
        XCTAssertEqual(shapes.count, 3)
        let withHole: [Extrusion.Shape] = shapes.filter { !$0.holes.isEmpty }
        XCTAssertEqual(withHole.count, 1)
        for shape in shapes {
            XCTAssertGreaterThan(Extrusion.signedArea(shape.outer), 0)
            for hole in shape.holes {
                XCTAssertLessThan(Extrusion.signedArea(hole), 0)
            }
        }
    }

    func testExtrusionIsClosedAndFacesOutward() {
        let shapes: [Extrusion.Shape] = Extrusion.shapes(from: [square(0, 0, 4), square(1, 1, 2)])
        let flat: MeshData = Extrusion.extrude(shapes, depth: 1, bevel: 0)
        XCTAssertEqual(signedVolume(flat), 12, accuracy: 1e-4)
        XCTAssertEqual(windingAgreement(flat), 1, accuracy: 1e-9)
        let bounds = flat.bounds
        XCTAssertEqual(Double(bounds.min.z), -0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(bounds.max.z), 0.5, accuracy: 1e-6)
        XCTAssertEqual(flat.parts.map { $0.material }, [0, 1])

        let beveled: MeshData = Extrusion.extrude(shapes, depth: 1, bevel: 0.1)
        let volume: Double = signedVolume(beveled)
        XCTAssertGreaterThan(volume, 10.5)
        XCTAssertLessThan(volume, 12)
        XCTAssertEqual(windingAgreement(beveled), 1, accuracy: 1e-9)
    }

    func testRoundContourGetsSmoothSides() {
        var circle: [SIMD2<Double>] = []
        for i in 0..<64 {
            let a: Double = Double(i) / 64 * 2 * Double.pi
            circle.append(SIMD2<Double>(cos(a), sin(a)))
        }
        let mesh: MeshData = Extrusion.extrude(Extrusion.shapes(from: [circle]), depth: 0.5, bevel: 0.05)
        XCTAssertGreaterThan(signedVolume(mesh), 0)
        // 円の側面では、隣り合う四角形の境目で法線が同じ（なめらか）
        let sides: MeshPart = mesh.parts[1]
        let first: Int = Int(mesh.indices[sides.start])
        let n: SIMD3<Float> = mesh.normals[first]
        XCTAssertLessThan(abs(n.z), 1e-5)
        XCTAssertEqual(Double((n.x * n.x + n.y * n.y).squareRoot()), 1, accuracy: 1e-4)
    }

    func testPrimitivesAreUnitSizedClosedMeshes() {
        for kind in Object3DKind.primitives {
            let mesh: MeshData = Primitives.mesh(kind)
            XCTAssertFalse(mesh.isEmpty, kind.rawValue)
            let b = mesh.bounds
            let extent: SIMD3<Float> = b.max - b.min
            XCTAssertEqual(Double(max(extent.x, max(extent.y, extent.z))), 1, accuracy: 0.01, kind.rawValue)
            XCTAssertGreaterThan(signedVolume(mesh), 0, kind.rawValue)
            XCTAssertGreaterThan(windingAgreement(mesh), 0.99, kind.rawValue)
        }
        XCTAssertEqual(signedVolume(Primitives.mesh(.cube)), 1, accuracy: 1e-5)
    }

    func testNormalizeCentersAndScales() {
        var mesh: MeshData = Extrusion.extrude(Extrusion.shapes(from: [square(10, 10, 4)]), depth: 2, bevel: 0)
        mesh.normalize(byHeight: true)
        let b = mesh.bounds
        XCTAssertEqual(Double(b.max.y - b.min.y), 1, accuracy: 1e-5)
        XCTAssertEqual(Double(b.min.x + b.max.x), 0, accuracy: 1e-5)
        XCTAssertEqual(Double(b.min.z + b.max.z), 0, accuracy: 1e-5)
    }

    func testObject3DCodingAndKeyframeSplit() throws {
        var clip = Clip(kind: .object3D, name: "3D", start: .zero, duration: Time(seconds: 4))
        var content = Object3DContent(kind: .text, text: "DISTRO")
        content.positionZ = Param(value: 0, keys: [ParamKey(time: .zero, value: 0, easing: .linear),
                                                     ParamKey(time: Time(seconds: 4), value: 1, easing: .linear)])
        clip.object3D = content
        let data: Data = try JSONEncoder().encode(clip)
        let decoded: Clip = try JSONDecoder().decode(Clip.self, from: data)
        XCTAssertEqual(decoded.object3D, content)
        XCTAssertEqual(decoded.kind, .object3D)
        // 最小の JSON でも既定値で読める
        let minimal: Object3DContent = try JSONDecoder().decode(Object3DContent.self, from: Data("{\"kind\":\"cube\"}".utf8))
        XCTAssertEqual(minimal.kind, .cube)
        XCTAssertEqual(minimal.fieldOfView, 35)
        // 分割すると奥行きのキーフレームも分かれる
        let halves: (Clip, Clip) = clip.splitKeyframes(at: Time(seconds: 2))
        let left: Double = halves.0.object3D?.positionZ.value(at: Time(seconds: 2)) ?? -1
        let right: Double = halves.1.object3D?.positionZ.value(at: .zero) ?? -1
        XCTAssertEqual(left, 0.5, accuracy: 1e-6)
        XCTAssertEqual(right, 0.5, accuracy: 1e-6)
    }

    func testModelFilesBecome3DClips() {
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "USDZ"), .model3D)
        XCTAssertEqual(MediaFormatSupport.kind(forExtension: "obj"), .model3D)
        let asset = MediaAsset(kind: .model3D, name: "robot", storage: .copied)
        let clip: Clip = Project(name: "m", canvas: CanvasSettings(aspect: .landscape16x9)).makeClip(for: asset)
        XCTAssertEqual(clip.kind, .object3D)
        XCTAssertEqual(clip.object3D?.kind, .model)
        XCTAssertEqual(clip.mediaID, asset.id)
    }
}
