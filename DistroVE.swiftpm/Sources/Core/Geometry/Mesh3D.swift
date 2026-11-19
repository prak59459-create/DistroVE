import Foundation

/// 材質の区切り（indices の範囲）。material は 0 = 表面、1 = 側面（文字）、モデルでは部品ごとの番号。
struct MeshPart: Hashable, Sendable {
    var start: Int
    var count: Int
    var material: Int
}

/// 三角形の集まり。GPU にそのまま渡せる並び（位置・法線・UV と添字）。
struct MeshData: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []
    var parts: [MeshPart] = []

    var vertexCount: Int { return positions.count }
    var triangleCount: Int { return indices.count / 3 }
    var isEmpty: Bool { return indices.isEmpty }

    mutating func addVertex(_ p: SIMD3<Float>, _ n: SIMD3<Float>, _ uv: SIMD2<Float> = SIMD2<Float>(0, 0)) -> UInt32 {
        let index: UInt32 = UInt32(positions.count)
        positions.append(p)
        normals.append(n)
        uvs.append(uv)
        return index
    }

    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        indices.append(a)
        indices.append(b)
        indices.append(c)
    }

    /// 四角形 a-b-c-d を 2 つの三角形にする。
    mutating func addQuad(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) {
        addTriangle(a, b, c)
        addTriangle(a, c, d)
    }

    /// 別の立体を後ろにつなぐ。material は付け足す部分の材質番号。
    mutating func append(_ other: MeshData, material: Int) {
        if other.isEmpty { return }
        let offset: UInt32 = UInt32(positions.count)
        let start: Int = indices.count
        positions.append(contentsOf: other.positions)
        normals.append(contentsOf: other.normals)
        uvs.append(contentsOf: other.uvs)
        for i in other.indices {
            indices.append(i + offset)
        }
        parts.append(MeshPart(start: start, count: other.indices.count, material: material))
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0)) }
        var hi: SIMD3<Float> = lo
        for p in positions {
            lo = SIMD3<Float>(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3<Float>(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        return (lo, hi)
    }

    /// 中心を原点に移し、byHeight なら高さ、そうでなければいちばん長い辺を 1 にする。
    mutating func normalize(byHeight: Bool) {
        let b: (min: SIMD3<Float>, max: SIMD3<Float>) = bounds
        let center: SIMD3<Float> = (b.min + b.max) * 0.5
        let extent: SIMD3<Float> = b.max - b.min
        let longest: Float = max(extent.x, max(extent.y, extent.z))
        let reference: Float = byHeight ? extent.y : longest
        let scale: Float = reference > 0.000001 ? 1 / reference : 1
        for i in positions.indices {
            positions[i] = (positions[i] - center) * scale
        }
    }
}

// MARK: 押し出し（3D 文字）

/// 平面の輪郭を押し出して立体にする。表と裏は Earcut で埋め、側面と面取りを付ける。
enum Extrusion {
    struct Shape: Sendable {
        /// 反時計回り
        var outer: [SIMD2<Double>]
        /// 時計回り
        var holes: [[SIMD2<Double>]]
    }

    /// 符号付き面積（反時計回りで正）。
    static func signedArea(_ ring: [SIMD2<Double>]) -> Double {
        if ring.count < 3 { return 0 }
        var sum: Double = 0
        var j: Int = ring.count - 1
        for i in 0..<ring.count {
            sum += (ring[j].x * ring[i].y) - (ring[i].x * ring[j].y)
            j = i
        }
        return sum / 2
    }

    /// 点が輪の内側にあるか（偶奇の規則）。
    static func contains(_ ring: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        var inside: Bool = false
        var j: Int = ring.count - 1
        for i in 0..<ring.count {
            let a: SIMD2<Double> = ring[i]
            let b: SIMD2<Double> = ring[j]
            if (a.y > point.y) != (b.y > point.y) {
                let crossX: Double = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossX { inside = !inside }
            }
            j = i
        }
        return inside
    }

    /// 続けて同じ点と、閉じるための最後の点を取り除く。
    static func cleaned(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var result: [SIMD2<Double>] = []
        for p in ring {
            if let last = result.last, Extrusion.distance(last, p) < 1e-7 { continue }
            result.append(p)
        }
        while result.count > 1, let first = result.first, let last = result.last, Extrusion.distance(first, last) < 1e-7 {
            result.removeLast()
        }
        return result
    }

    static func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d: SIMD2<Double> = a - b
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    static func oriented(_ ring: [SIMD2<Double>], counterClockwise: Bool) -> [SIMD2<Double>] {
        let isCCW: Bool = Extrusion.signedArea(ring) > 0
        return isCCW == counterClockwise ? ring : Array(ring.reversed())
    }

    /// 輪郭の集まりを、外側の輪とその穴に分ける（入れ子の深さが偶数なら外側、奇数なら穴）。
    static func shapes(from contours: [[SIMD2<Double>]]) -> [Shape] {
        var rings: [[SIMD2<Double>]] = []
        for contour in contours {
            let ring: [SIMD2<Double>] = Extrusion.cleaned(contour)
            if ring.count >= 3 && abs(Extrusion.signedArea(ring)) > 1e-9 { rings.append(ring) }
        }
        let n: Int = rings.count
        var areas: [Double] = []
        for ring in rings {
            areas.append(abs(Extrusion.signedArea(ring)))
        }
        var depth: [Int] = Array(repeating: 0, count: n)
        var parent: [Int] = Array(repeating: -1, count: n)
        for i in 0..<n {
            var smallest: Double = Double.infinity
            for j in 0..<n where j != i && areas[j] > areas[i] {
                if Extrusion.contains(rings[j], rings[i][0]) {
                    depth[i] += 1
                    if areas[j] < smallest {
                        smallest = areas[j]
                        parent[i] = j
                    }
                }
            }
        }
        var shapes: [Shape] = []
        var shapeOfRing: [Int: Int] = [:]
        for i in 0..<n where depth[i] % 2 == 0 {
            shapeOfRing[i] = shapes.count
            shapes.append(Shape(outer: Extrusion.oriented(rings[i], counterClockwise: true), holes: []))
        }
        for i in 0..<n where depth[i] % 2 == 1 {
            guard parent[i] >= 0, let s = shapeOfRing[parent[i]] else { continue }
            shapes[s].holes.append(Extrusion.oriented(rings[i], counterClockwise: false))
        }
        return shapes
    }

    /// 押し出した立体。depth と bevel は輪郭と同じ単位。材質 0 = 表と裏、1 = 側面と面取り。
    static func extrude(_ shapes: [Shape], depth: Double, bevel: Double) -> MeshData {
        let half: Double = max(0.0001, depth / 2)
        let b: Double = max(0, min(bevel, half * 0.9))
        var caps = MeshData()
        var sides = MeshData()
        for shape in shapes {
            let outerInset: [SIMD2<Double>] = b > 0 ? Extrusion.inset(shape.outer, by: b) : shape.outer
            var holesInset: [[SIMD2<Double>]] = []
            for hole in shape.holes {
                holesInset.append(b > 0 ? Extrusion.inset(hole, by: b) : hole)
            }
            let tri: (points: [SIMD2<Double>], indices: [Int]) = Earcut.triangulate(outer: outerInset, holes: holesInset)
            Extrusion.appendCap(&caps, points: tri.points, indices: tri.indices, z: half, front: true)
            Extrusion.appendCap(&caps, points: tri.points, indices: tri.indices, z: -half, front: false)
            Extrusion.appendSides(&sides, ring: shape.outer, inset: outerInset, half: half, bevel: b)
            for (k, hole) in shape.holes.enumerated() {
                Extrusion.appendSides(&sides, ring: hole, inset: holesInset[k], half: half, bevel: b)
            }
        }
        var mesh = MeshData()
        mesh.append(caps, material: 0)
        mesh.append(sides, material: 1)
        return mesh
    }

    /// 平らな面（表なら +Z 向き、裏なら -Z 向き）。三角形の向きを法線に合わせる。
    static func appendCap(_ mesh: inout MeshData, points: [SIMD2<Double>], indices: [Int], z: Double, front: Bool) {
        if indices.isEmpty { return }
        let base: UInt32 = UInt32(mesh.positions.count)
        let normal = SIMD3<Float>(0, 0, front ? 1 : -1)
        for p in points {
            let position = SIMD3<Float>(Float(p.x), Float(p.y), Float(z))
            _ = mesh.addVertex(position, normal, SIMD2<Float>(Float(p.x), Float(p.y)))
        }
        var k: Int = 0
        while k + 2 < indices.count {
            let a: Int = indices[k]
            var b: Int = indices[k + 1]
            var c: Int = indices[k + 2]
            let cross: Double = Extrusion.cross(points[a], points[b], points[c])
            if (cross < 0) == front {
                swap(&b, &c)
            }
            mesh.addTriangle(base + UInt32(a), base + UInt32(b), base + UInt32(c))
            k += 3
        }
    }

    static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        let ab: SIMD2<Double> = b - a
        let ac: SIMD2<Double> = c - a
        return ab.x * ac.y - ab.y * ac.x
    }

    /// 辺の外向きの法線。外側の輪（反時計回り）でも穴（時計回り）でも、立体の外を向く。
    static func edgeNormals(_ ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var result: [SIMD2<Double>] = []
        let n: Int = ring.count
        for i in 0..<n {
            let d: SIMD2<Double> = ring[(i + 1) % n] - ring[i]
            let length: Double = max(1e-12, (d.x * d.x + d.y * d.y).squareRoot())
            result.append(SIMD2<Double>(d.y / length, -d.x / length))
        }
        return result
    }

    /// 頂点ごとの法線。角がなだらか（35 度未満）なら両側の平均、そうでなければ nil（角を立てる）。
    static func smoothNormals(_ edges: [SIMD2<Double>]) -> [SIMD2<Double>?] {
        var result: [SIMD2<Double>?] = []
        let n: Int = edges.count
        let limit: Double = cos(35 * Double.pi / 180)
        for i in 0..<n {
            let before: SIMD2<Double> = edges[(i + n - 1) % n]
            let after: SIMD2<Double> = edges[i]
            let dot: Double = before.x * after.x + before.y * after.y
            if dot >= limit {
                let sum: SIMD2<Double> = before + after
                let length: Double = max(1e-12, (sum.x * sum.x + sum.y * sum.y).squareRoot())
                result.append(sum / length)
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// 輪郭を立体の内側へ b だけ縮める（角は留め継ぎ。とがりすぎないよう 3b までに抑える）。
    static func inset(_ ring: [SIMD2<Double>], by b: Double) -> [SIMD2<Double>] {
        let edges: [SIMD2<Double>] = Extrusion.edgeNormals(ring)
        let n: Int = ring.count
        var result: [SIMD2<Double>] = []
        for i in 0..<n {
            let before: SIMD2<Double> = edges[(i + n - 1) % n]
            let after: SIMD2<Double> = edges[i]
            let sum: SIMD2<Double> = before + after
            let length: Double = (sum.x * sum.x + sum.y * sum.y).squareRoot()
            if length < 1e-9 {
                result.append(ring[i] - after * b)
                continue
            }
            let miter: SIMD2<Double> = sum / length
            let cosine: Double = max(0.33, miter.x * after.x + miter.y * after.y)
            let distance: Double = min(3 * b, b / cosine)
            result.append(ring[i] - miter * distance)
        }
        return result
    }

    /// 側面（と面取り）。四角形を辺ごとに作り、なめらかな角では法線を平均する。
    static func appendSides(_ mesh: inout MeshData, ring: [SIMD2<Double>], inset: [SIMD2<Double>], half: Double, bevel b: Double) {
        let n: Int = ring.count
        if n < 3 { return }
        let edges: [SIMD2<Double>] = Extrusion.edgeNormals(ring)
        let smooth: [SIMD2<Double>?] = Extrusion.smoothNormals(edges)
        let zFront: Float = Float(half - b)
        let zBack: Float = Float(-half + b)
        for i in 0..<n {
            let j: Int = (i + 1) % n
            let startNormal: SIMD2<Double> = smooth[i] ?? edges[i]
            let endNormal: SIMD2<Double> = smooth[j] ?? edges[i]
            let p0: SIMD2<Float> = SIMD2<Float>(Float(ring[i].x), Float(ring[i].y))
            let p1: SIMD2<Float> = SIMD2<Float>(Float(ring[j].x), Float(ring[j].y))
            let n0: SIMD3<Float> = SIMD3<Float>(Float(startNormal.x), Float(startNormal.y), 0)
            let n1: SIMD3<Float> = SIMD3<Float>(Float(endNormal.x), Float(endNormal.y), 0)
            Extrusion.appendWall(&mesh, p0, p1, n0, n1, zTop: zFront, zBottom: zBack)
            if b > 0 {
                let q0: SIMD2<Float> = SIMD2<Float>(Float(inset[i].x), Float(inset[i].y))
                let q1: SIMD2<Float> = SIMD2<Float>(Float(inset[j].x), Float(inset[j].y))
                let zCap: Float = Float(half)
                Extrusion.appendBevel(&mesh, outer: (p0, p1), inner: (q0, q1), normals: (n0, n1), zOuter: zFront, zInner: zCap, towardFront: true)
                Extrusion.appendBevel(&mesh, outer: (p0, p1), inner: (q0, q1), normals: (n0, n1), zOuter: zBack, zInner: -zCap, towardFront: false)
            }
        }
    }

    /// 縦の壁（表側 zTop から裏側 zBottom まで）。外から見て反時計回りの向きにする。
    static func appendWall(_ mesh: inout MeshData, _ p0: SIMD2<Float>, _ p1: SIMD2<Float>, _ n0: SIMD3<Float>, _ n1: SIMD3<Float>,
                           zTop: Float, zBottom: Float) {
        let a: UInt32 = mesh.addVertex(SIMD3<Float>(p0.x, p0.y, zTop), n0)
        let b: UInt32 = mesh.addVertex(SIMD3<Float>(p1.x, p1.y, zTop), n1)
        let c: UInt32 = mesh.addVertex(SIMD3<Float>(p1.x, p1.y, zBottom), n1)
        let d: UInt32 = mesh.addVertex(SIMD3<Float>(p0.x, p0.y, zBottom), n0)
        mesh.addQuad(a, d, c, b)
    }

    /// 面取り（45 度の斜面）。外側の辺（zOuter）から内側に縮めた辺（zInner）へ。
    static func appendBevel(_ mesh: inout MeshData, outer: (SIMD2<Float>, SIMD2<Float>), inner: (SIMD2<Float>, SIMD2<Float>),
                            normals: (SIMD3<Float>, SIMD3<Float>), zOuter: Float, zInner: Float, towardFront: Bool) {
        let tilt: Float = towardFront ? 1 : -1
        let m0: SIMD3<Float> = Extrusion.normalized(SIMD3<Float>(normals.0.x, normals.0.y, tilt))
        let m1: SIMD3<Float> = Extrusion.normalized(SIMD3<Float>(normals.1.x, normals.1.y, tilt))
        let a: UInt32 = mesh.addVertex(SIMD3<Float>(inner.0.x, inner.0.y, zInner), m0)
        let b: UInt32 = mesh.addVertex(SIMD3<Float>(inner.1.x, inner.1.y, zInner), m1)
        let c: UInt32 = mesh.addVertex(SIMD3<Float>(outer.1.x, outer.1.y, zOuter), m1)
        let d: UInt32 = mesh.addVertex(SIMD3<Float>(outer.0.x, outer.0.y, zOuter), m0)
        if towardFront {
            mesh.addQuad(a, d, c, b)
        } else {
            mesh.addQuad(a, b, c, d)
        }
    }

    static func normalized(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let length: Float = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
        return length > 0.000001 ? v / length : v
    }
}

// MARK: 基本の立体

/// 立方体・球・円柱・円すい・ドーナツ。どれも原点中心で、いちばん長い辺が 1。
enum Primitives {
    static func mesh(_ kind: Object3DKind) -> MeshData {
        var body = MeshData()
        switch kind {
        case .cube: body = Primitives.cube()
        case .sphere: body = Primitives.sphere(segments: 48, rings: 24)
        case .cylinder: body = Primitives.cylinder(segments: 48)
        case .cone: body = Primitives.cone(segments: 48)
        case .torus: body = Primitives.torus(segments: 56, sides: 24)
        case .text, .model: break
        }
        var mesh = MeshData()
        mesh.append(body, material: 0)
        return mesh
    }

    /// 立方体の 1 面（法線と、面に沿った 2 つの向き）。
    struct CubeFace {
        let normal: SIMD3<Float>
        let u: SIMD3<Float>
        let v: SIMD3<Float>
    }

    /// SIMD の式は型チェックが重いので、作るところは関数に分ける。
    static func vec(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> {
        return SIMD3<Float>(x, y, z)
    }

    static func uv(_ u: Float, _ v: Float) -> SIMD2<Float> {
        return SIMD2<Float>(u, v)
    }

    static var cubeFaces: [CubeFace] {
        return [
            CubeFace(normal: vec(0, 0, 1), u: vec(1, 0, 0), v: vec(0, 1, 0)),
            CubeFace(normal: vec(0, 0, -1), u: vec(-1, 0, 0), v: vec(0, 1, 0)),
            CubeFace(normal: vec(1, 0, 0), u: vec(0, 0, -1), v: vec(0, 1, 0)),
            CubeFace(normal: vec(-1, 0, 0), u: vec(0, 0, 1), v: vec(0, 1, 0)),
            CubeFace(normal: vec(0, 1, 0), u: vec(1, 0, 0), v: vec(0, 0, -1)),
            CubeFace(normal: vec(0, -1, 0), u: vec(1, 0, 0), v: vec(0, 0, 1))
        ]
    }

    static func cube() -> MeshData {
        var mesh = MeshData()
        for face in Primitives.cubeFaces {
            Primitives.appendFace(&mesh, face)
        }
        return mesh
    }

    static func appendFace(_ mesh: inout MeshData, _ face: CubeFace) {
        let half: Float = 0.5
        let center: SIMD3<Float> = face.normal * half
        let du: SIMD3<Float> = face.u * half
        let dv: SIMD3<Float> = face.v * half
        let low: SIMD3<Float> = center - dv
        let high: SIMD3<Float> = center + dv
        let p0: SIMD3<Float> = low - du
        let p1: SIMD3<Float> = low + du
        let p2: SIMD3<Float> = high + du
        let p3: SIMD3<Float> = high - du
        let a: UInt32 = mesh.addVertex(p0, face.normal, uv(0, 1))
        let b: UInt32 = mesh.addVertex(p1, face.normal, uv(1, 1))
        let c: UInt32 = mesh.addVertex(p2, face.normal, uv(1, 0))
        let d: UInt32 = mesh.addVertex(p3, face.normal, uv(0, 0))
        mesh.addQuad(a, b, c, d)
    }

    static func sphere(segments: Int, rings: Int) -> MeshData {
        var mesh = MeshData()
        for r in 0...rings {
            let v: Float = Float(r) / Float(rings)
            let phi: Float = v * Float.pi
            for s in 0...segments {
                let u: Float = Float(s) / Float(segments)
                let theta: Float = u * 2 * Float.pi
                let ring: Float = sin(phi)
                let n: SIMD3<Float> = vec(ring * sin(theta), cos(phi), ring * cos(theta))
                let p: SIMD3<Float> = n * Float(0.5)
                _ = mesh.addVertex(p, n, uv(u, v))
            }
        }
        let row: Int = segments + 1
        for r in 0..<rings {
            for s in 0..<segments {
                let a: UInt32 = UInt32(r * row + s)
                let b: UInt32 = UInt32((r + 1) * row + s)
                mesh.addQuad(a, b, b + 1, a + 1)
            }
        }
        return mesh
    }

    /// 側面（radiusTop から radiusBottom へ）と上下のふた。
    static func lathe(segments: Int, radiusTop: Float, radiusBottom: Float) -> MeshData {
        var mesh = MeshData()
        let slope: Float = (radiusBottom - radiusTop)
        for s in 0...segments {
            let u: Float = Float(s) / Float(segments)
            let theta: Float = u * 2 * Float.pi
            let dx: Float = sin(theta)
            let dz: Float = cos(theta)
            let normal: SIMD3<Float> = Extrusion.normalized(vec(dx, slope, dz))
            _ = mesh.addVertex(vec(dx * radiusTop, 0.5, dz * radiusTop), normal, uv(u, 0))
            _ = mesh.addVertex(vec(dx * radiusBottom, -0.5, dz * radiusBottom), normal, uv(u, 1))
        }
        for s in 0..<segments {
            let a: UInt32 = UInt32(s * 2)
            mesh.addQuad(a, a + 1, a + 3, a + 2)
        }
        if radiusTop > 0.0001 { Primitives.appendDisc(&mesh, segments: segments, radius: radiusTop, y: 0.5, up: true) }
        if radiusBottom > 0.0001 { Primitives.appendDisc(&mesh, segments: segments, radius: radiusBottom, y: -0.5, up: false) }
        return mesh
    }

    static func appendDisc(_ mesh: inout MeshData, segments: Int, radius: Float, y: Float, up: Bool) {
        let normal: SIMD3<Float> = vec(0, up ? 1 : -1, 0)
        let center: UInt32 = mesh.addVertex(vec(0, y, 0), normal, uv(0.5, 0.5))
        let first: UInt32 = UInt32(mesh.positions.count)
        for s in 0...segments {
            let theta: Float = Float(s) / Float(segments) * 2 * Float.pi
            let sx: Float = sin(theta)
            let sz: Float = cos(theta)
            _ = mesh.addVertex(vec(sx * radius, y, sz * radius), normal, uv(0.5 + sx * 0.5, 0.5 + sz * 0.5))
        }
        for s in 0..<segments {
            let a: UInt32 = first + UInt32(s)
            if up {
                mesh.addTriangle(center, a, a + 1)
            } else {
                mesh.addTriangle(center, a + 1, a)
            }
        }
    }

    static func cylinder(segments: Int) -> MeshData {
        return Primitives.lathe(segments: segments, radiusTop: 0.5, radiusBottom: 0.5)
    }

    static func cone(segments: Int) -> MeshData {
        return Primitives.lathe(segments: segments, radiusTop: 0, radiusBottom: 0.5)
    }

    /// 画面のほうを向いた輪（穴が見える向き）。
    static func torus(segments: Int, sides: Int) -> MeshData {
        var mesh = MeshData()
        let major: Float = 0.35
        let minor: Float = 0.15
        for s in 0...segments {
            let u: Float = Float(s) / Float(segments)
            let theta: Float = u * 2 * Float.pi
            let cx: Float = cos(theta)
            let cy: Float = sin(theta)
            for k in 0...sides {
                let v: Float = Float(k) / Float(sides)
                let phi: Float = v * 2 * Float.pi
                let spread: Float = cos(phi)
                let normal: SIMD3<Float> = vec(cx * spread, cy * spread, sin(phi))
                let reach: Float = major + minor * spread
                let position: SIMD3<Float> = vec(cx * reach, cy * reach, minor * sin(phi))
                _ = mesh.addVertex(position, normal, uv(u, v))
            }
        }
        let row: Int = sides + 1
        for s in 0..<segments {
            for k in 0..<sides {
                let a: UInt32 = UInt32(s * row + k)
                let b: UInt32 = UInt32((s + 1) * row + k)
                mesh.addQuad(a, b, b + 1, a + 1)
            }
        }
        return mesh
    }
}
