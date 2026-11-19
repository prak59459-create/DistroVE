#if canImport(CoreText) && canImport(ModelIO)
import CoreGraphics
import CoreText
import Foundation
import ModelIO
import simd

/// 3D の形を用意する（Q50）。文字は CoreText の輪郭を押し出し、モデルは ModelIO で読む。
enum Geometry3D {
    // MARK: 文字

    static func font(name: String, bold: Bool) -> CTFont {
        let base: CTFont
        if name.isEmpty {
            base = CTFontCreateUIFontForLanguage(.system, 1, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 1, nil)
        } else {
            base = CTFontCreateWithName(name as CFString, 1, nil)
        }
        if !bold { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, 1, nil, .traitBold, .traitBold) ?? base
    }

    /// 文字の立体。高さ 1（行の高さ基準）・原点中心にそろえる。材質 0 = 表と裏、1 = 側面。
    static func textMesh(_ content: Object3DContent) -> MeshData {
        let font: CTFont = Geometry3D.font(name: content.fontName, bold: content.bold)
        let contours: [[SIMD2<Double>]] = Geometry3D.textContours(content.text, font: font)
        let lineHeight: Double = Geometry3D.lineHeight(font)
        let shapes: [Extrusion.Shape] = Extrusion.shapes(from: contours)
        var mesh: MeshData = Extrusion.extrude(shapes, depth: content.depth * lineHeight, bevel: content.bevel * lineHeight)
        mesh.normalize(byHeight: true)
        return mesh
    }

    static func lineHeight(_ font: CTFont) -> Double {
        let ascent: Double = Double(CTFontGetAscent(font))
        let descent: Double = Double(CTFontGetDescent(font))
        let leading: Double = Double(CTFontGetLeading(font))
        return max(0.5, ascent + descent + leading)
    }

    /// 行ごとに中央そろえした文字の輪郭。
    static func textContours(_ text: String, font: CTFont) -> [[SIMD2<Double>]] {
        let lines: [String] = text.components(separatedBy: "\n")
        let step: Double = Geometry3D.lineHeight(font)
        var contours: [[SIMD2<Double>]] = []
        let key = NSAttributedString.Key(rawValue: kCTFontAttributeName as String)
        for (index, line) in lines.enumerated() {
            if line.isEmpty { continue }
            let attributed = NSAttributedString(string: line, attributes: [key: font])
            let ctLine: CTLine = CTLineCreateWithAttributedString(attributed)
            let width: Double = Double(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            let offset = CGPoint(x: -width / 2, y: -Double(index) * step)
            contours.append(contentsOf: Geometry3D.lineContours(ctLine, font: font, offset: offset))
        }
        return contours
    }

    static func lineContours(_ line: CTLine, font: CTFont, offset: CGPoint) -> [[SIMD2<Double>]] {
        var contours: [[SIMD2<Double>]] = []
        let runs: [CTRun] = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        for run in runs {
            let count: Int = CTRunGetGlyphCount(run)
            if count == 0 { continue }
            var glyphs: [CGGlyph] = Array(repeating: 0, count: count)
            var positions: [CGPoint] = Array(repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let runFont: CTFont = Geometry3D.font(of: run) ?? font
            for i in 0..<count {
                var transform = CGAffineTransform(translationX: positions[i].x + offset.x, y: positions[i].y + offset.y)
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[i], &transform) else { continue }
                contours.append(contentsOf: Geometry3D.flatten(path))
            }
        }
        return contours
    }

    /// 日本語などで代わりに使われたフォント。
    static func font(of run: CTRun) -> CTFont? {
        let attributes: NSDictionary = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName as String] else { return nil }
        return (value as! CTFont)
    }

    /// 曲線を折れ線にする（長さに応じて 4〜24 分割）。
    static func flatten(_ path: CGPath) -> [[SIMD2<Double>]] {
        var contours: [[SIMD2<Double>]] = []
        var current: [SIMD2<Double>] = []
        var last = SIMD2<Double>(0, 0)
        path.applyWithBlock { (pointer: UnsafePointer<CGPathElement>) in
            let element: CGPathElement = pointer.pointee
            switch element.type {
            case .moveToPoint:
                if current.count >= 3 { contours.append(current) }
                last = Geometry3D.vector(element.points[0])
                current = [last]
            case .addLineToPoint:
                last = Geometry3D.vector(element.points[0])
                current.append(last)
            case .addQuadCurveToPoint:
                let c: SIMD2<Double> = Geometry3D.vector(element.points[0])
                let p: SIMD2<Double> = Geometry3D.vector(element.points[1])
                let n: Int = Geometry3D.segments(Extrusion.distance(last, c) + Extrusion.distance(c, p))
                let start: SIMD2<Double> = last
                for k in 1...n {
                    let t: Double = Double(k) / Double(n)
                    current.append(Geometry3D.quadratic(start, c, p, t))
                }
                last = p
            case .addCurveToPoint:
                let c1: SIMD2<Double> = Geometry3D.vector(element.points[0])
                let c2: SIMD2<Double> = Geometry3D.vector(element.points[1])
                let p: SIMD2<Double> = Geometry3D.vector(element.points[2])
                let length: Double = Extrusion.distance(last, c1) + Extrusion.distance(c1, c2) + Extrusion.distance(c2, p)
                let n: Int = Geometry3D.segments(length)
                let start: SIMD2<Double> = last
                for k in 1...n {
                    let t: Double = Double(k) / Double(n)
                    current.append(Geometry3D.cubic(start, c1, c2, p, t))
                }
                last = p
            case .closeSubpath:
                if current.count >= 3 { contours.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if current.count >= 3 { contours.append(current) }
        return contours
    }

    static func vector(_ p: CGPoint) -> SIMD2<Double> {
        return SIMD2<Double>(Double(p.x), Double(p.y))
    }

    static func segments(_ length: Double) -> Int {
        return max(4, min(24, Int(length * 48)))
    }

    /// 2 次の曲線。成分ごとに計算する（SIMD の式は型チェックが重いため）。
    static func quadratic(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
        let u: Double = 1 - t
        let w0: Double = u * u
        let w1: Double = 2 * u * t
        let w2: Double = t * t
        let x: Double = a.x * w0 + b.x * w1 + c.x * w2
        let y: Double = a.y * w0 + b.y * w1 + c.y * w2
        return SIMD2<Double>(x, y)
    }

    static func cubic(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>, _ t: Double) -> SIMD2<Double> {
        let u: Double = 1 - t
        let w0: Double = u * u * u
        let w1: Double = 3 * u * u * t
        let w2: Double = 3 * u * t * t
        let w3: Double = t * t * t
        let x: Double = a.x * w0 + b.x * w1 + c.x * w2 + d.x * w3
        let y: Double = a.y * w0 + b.y * w1 + c.y * w2 + d.y * w3
        return SIMD2<Double>(x, y)
    }

    // MARK: モデル

    /// モデルの材質（部品ごと）。
    struct ModelMaterial {
        var color: SIMD4<Float>
        var metallic: Float
        var roughness: Float
        var texture: MDLTexture?
        var textureURL: URL?
    }

    struct LoadedModel {
        /// parts の material は materials の添字
        var mesh: MeshData
        var materials: [ModelMaterial]
    }

    /// USDZ・OBJ・STL・PLY などを読む。形はいちばん長い辺を 1 にそろえる。
    static func loadModel(url: URL) throws -> LoadedModel {
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: nil, preserveTopology: false, error: nil)
        asset.loadTextures()
        var result = LoadedModel(mesh: MeshData(), materials: [])
        let objects: [MDLObject] = asset.childObjects(of: MDLMesh.self)
        for object in objects {
            guard let mesh = object as? MDLMesh else { continue }
            Geometry3D.append(mesh, to: &result)
        }
        if result.mesh.isEmpty {
            throw EngineError.unreadable("3D モデルの形が見つかりません")
        }
        result.mesh.normalize(byHeight: false)
        return result
    }

    static func append(_ mesh: MDLMesh, to result: inout LoadedModel) {
        if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.6)
        }
        guard let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else { return }
        let normals: MDLVertexAttributeData? = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3)
        let uvs: MDLVertexAttributeData? = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2)
        let world: simd_float4x4 = MDLTransform.globalTransform(with: mesh, atTime: 0)
        let rotation = simd_float3x3(SIMD3<Float>(world.columns.0.x, world.columns.0.y, world.columns.0.z),
                                     SIMD3<Float>(world.columns.1.x, world.columns.1.y, world.columns.1.z),
                                     SIMD3<Float>(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        let normalMatrix: simd_float3x3 = rotation.inverse.transpose
        // 頂点は 1 回だけ足し、部品（submesh）ごとに添字の範囲と材質を分ける
        let offset: UInt32 = UInt32(result.mesh.positions.count)
        for v in 0..<mesh.vertexCount {
            let p: SIMD3<Float> = Geometry3D.float3(positions, v)
            let wp: SIMD4<Float> = world * SIMD4<Float>(p.x, p.y, p.z, 1)
            let n: SIMD3<Float> = normals.map { Geometry3D.float3($0, v) } ?? SIMD3<Float>(0, 1, 0)
            let uv: SIMD2<Float> = uvs.map { Geometry3D.float2($0, v) } ?? SIMD2<Float>(0, 0)
            _ = result.mesh.addVertex(SIMD3<Float>(wp.x, wp.y, wp.z), Extrusion.normalized(normalMatrix * n), uv)
        }
        let submeshes: [MDLSubmesh] = (mesh.submeshes as? [MDLSubmesh]) ?? []
        for submesh in submeshes where submesh.geometryType == .triangles {
            let buffer: MDLMeshBuffer = submesh.indexBuffer(asIndexType: .uInt32)
            let map: MDLMeshBufferMap = buffer.map()
            let indices: UnsafePointer<UInt32> = UnsafePointer(map.bytes.assumingMemoryBound(to: UInt32.self))
            let start: Int = result.mesh.indices.count
            for k in 0..<submesh.indexCount {
                result.mesh.indices.append(indices[k] + offset)
            }
            result.mesh.parts.append(MeshPart(start: start, count: submesh.indexCount, material: result.materials.count))
            result.materials.append(Geometry3D.material(submesh.material))
        }
    }

    static func float3(_ data: MDLVertexAttributeData, _ index: Int) -> SIMD3<Float> {
        let pointer: UnsafeMutablePointer<Float> = data.dataStart.advanced(by: index * data.stride).assumingMemoryBound(to: Float.self)
        return SIMD3<Float>(pointer[0], pointer[1], pointer[2])
    }

    static func float2(_ data: MDLVertexAttributeData, _ index: Int) -> SIMD2<Float> {
        let pointer: UnsafeMutablePointer<Float> = data.dataStart.advanced(by: index * data.stride).assumingMemoryBound(to: Float.self)
        return SIMD2<Float>(pointer[0], pointer[1])
    }

    static func material(_ source: MDLMaterial?) -> ModelMaterial {
        var result = ModelMaterial(color: SIMD4<Float>(0.8, 0.8, 0.8, 1), metallic: 0, roughness: 0.5, texture: nil, textureURL: nil)
        guard let m = source else { return result }
        if let base = m.property(with: .baseColor) {
            switch base.type {
            case .float3:
                let v: SIMD3<Float> = base.float3Value
                result.color = SIMD4<Float>(v.x, v.y, v.z, 1)
            case .float4:
                result.color = base.float4Value
            case .color:
                if let color = base.color, let parts = color.components, parts.count >= 3 {
                    result.color = SIMD4<Float>(Float(parts[0]), Float(parts[1]), Float(parts[2]), 1)
                }
            case .texture:
                result.texture = base.textureSamplerValue?.texture
            case .URL:
                result.textureURL = base.urlValue
            default:
                break
            }
        }
        if let metal = m.property(with: .metallic), metal.type == .float {
            result.metallic = metal.floatValue
        }
        if let rough = m.property(with: .roughness), rough.type == .float {
            result.roughness = rough.floatValue
        }
        return result
    }
}
#endif
