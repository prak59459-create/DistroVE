#if canImport(Metal) && canImport(MetalKit) && canImport(ModelIO)
import CoreImage
import CoreVideo
import Foundation
import Metal
import MetalKit
import ModelIO
import simd

/// 3D の 1 フレームを Metal で描く（Q50）。シェーダーは実行時にソースから作る（Swift Playgrounds は .metal を作れないため）。
/// 描いた絵は CVPixelBuffer に入れて Core Image へ渡し、ほかのレイヤーと同じように重ねる。
final class Renderer3D: @unchecked Sendable {
    static let shared: Renderer3D? = Renderer3D()

    /// 置き方。位置は画面に対する割合（右・下・手前が正）、回転は度。
    struct Pose {
        var positionX: Double = 0
        var positionY: Double = 0
        var positionZ: Double = 0
        var rotationX: Double = 0
        var rotationY: Double = 0
        var rotationZ: Double = 0
        var scale: Double = 1
    }

    struct ModelSource {
        let key: String
        let url: URL
    }

    private struct Uniforms {
        var model: simd_float4x4
        var viewProjection: simd_float4x4
        var normalMatrix: simd_float3x3
        var camera: SIMD4<Float>
    }

    private struct Light {
        var direction: SIMD4<Float>
        var color: SIMD4<Float>
    }

    private struct Lights {
        var key: Light
        var fill: Light
        var rim: Light
        var ambientTop: SIMD4<Float>
        var ambientBottom: SIMD4<Float>
    }

    private struct Surface {
        var color: SIMD4<Float>
        /// metallic, roughness, glow, flags（1 = テクスチャあり、2 = 両面）
        var params: SIMD4<Float>
    }

    private final class GPUMesh {
        let positions: MTLBuffer
        let normals: MTLBuffer
        let uvs: MTLBuffer
        let indices: MTLBuffer
        let parts: [MeshPart]
        let materials: [Geometry3D.ModelMaterial]
        let textures: [MTLTexture?]

        init(positions: MTLBuffer, normals: MTLBuffer, uvs: MTLBuffer, indices: MTLBuffer, parts: [MeshPart],
             materials: [Geometry3D.ModelMaterial], textures: [MTLTexture?]) {
            self.positions = positions
            self.normals = normals
            self.uvs = uvs
            self.indices = indices
            self.parts = parts
            self.materials = materials
            self.textures = textures
        }
    }

    let device: MTLDevice
    let sampleCount: Int
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let sampler: MTLSamplerState
    private let white: MTLTexture
    private let lock = NSLock()
    private var cache: [String: GPUMesh] = [:]
    private var cacheOrder: [String] = []
    private var failed: Set<String> = []
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var targetWidth: Int = 0
    private var targetHeight: Int = 0
    private var msaa: MTLTexture?
    private var depth: MTLTexture?
    private static let cacheLimit: Int = 24

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        guard let library = try? device.makeLibrary(source: Renderer3D.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "vertex3d"),
              let fragmentFunction = library.makeFunction(name: "fragment3d") else { return nil }
        let samples: Int = device.supportsTextureSampleCount(4) ? 4 : 1
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.rasterSampleCount = samples
        descriptor.vertexDescriptor = Renderer3D.vertexDescriptor()
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else { return nil }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
              let white = Renderer3D.whiteTexture(device) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        self.sampler = sampler
        self.white = white
        self.sampleCount = samples
        var created: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &created)
        self.textureCache = created
    }

    static func vertexDescriptor() -> MTLVertexDescriptor {
        let d = MTLVertexDescriptor()
        d.attributes[0].format = .float3
        d.attributes[0].offset = 0
        d.attributes[0].bufferIndex = 0
        d.attributes[1].format = .float3
        d.attributes[1].offset = 0
        d.attributes[1].bufferIndex = 1
        d.attributes[2].format = .float2
        d.attributes[2].offset = 0
        d.attributes[2].bufferIndex = 2
        d.layouts[0].stride = MemoryLayout<SIMD3<Float>>.stride
        d.layouts[1].stride = MemoryLayout<SIMD3<Float>>.stride
        d.layouts[2].stride = MemoryLayout<SIMD2<Float>>.stride
        return d
    }

    static func whiteTexture(_ device: MTLDevice) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        let pixel: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: pixel, bytesPerRow: 4)
        return texture
    }

    func clearCaches() {
        lock.lock()
        cache = [:]
        cacheOrder = []
        failed = []
        lock.unlock()
    }

    // MARK: 描画

    /// 透明な背景に 3D を描いた、キャンバスと同じ大きさの画像。
    func render(_ content: Object3DContent, pose: Pose, size: CGSize, model: ModelSource?) -> CIImage? {
        let width: Int = Int(size.width.rounded())
        let height: Int = Int(size.height.rounded())
        if width < 2 || height < 2 { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let mesh = gpuMesh(content, model: model) else { return nil }
        guard prepareTargets(width: width, height: height), let buffer = makePixelBuffer(),
              let cvTexture = metalTexture(for: buffer), let target = CVMetalTextureGetTexture(cvTexture) else { return nil }
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: passDescriptor(target: target)) else { return nil }
        encode(encoder, mesh: mesh, content: content, pose: pose, aspect: Float(width) / Float(height))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        if commands.status != .completed { return nil }
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: space])
    }

    private func encode(_ encoder: MTLRenderCommandEncoder, mesh: GPUMesh, content: Object3DContent, pose: Pose, aspect: Float) {
        var uniforms: Uniforms = Renderer3D.uniforms(content: content, pose: pose, aspect: aspect)
        var lights: Lights = Renderer3D.lights(content.lighting)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(mesh.positions, offset: 0, index: 0)
        encoder.setVertexBuffer(mesh.normals, offset: 0, index: 1)
        encoder.setVertexBuffer(mesh.uvs, offset: 0, index: 2)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        encoder.setFragmentBytes(&lights, length: MemoryLayout<Lights>.stride, index: 4)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for part in mesh.parts where part.count > 0 {
            let look: (surface: Surface, texture: MTLTexture?) = surface(for: part, mesh: mesh, content: content)
            var s: Surface = look.surface
            encoder.setFragmentBytes(&s, length: MemoryLayout<Surface>.stride, index: 5)
            encoder.setFragmentTexture(look.texture ?? white, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.count, indexType: .uint32,
                                          indexBuffer: mesh.indices, indexBufferOffset: part.start * MemoryLayout<UInt32>.stride)
        }
    }

    private func surface(for part: MeshPart, mesh: GPUMesh, content: Object3DContent) -> (surface: Surface, texture: MTLTexture?) {
        let m: Material3D = content.material
        let glow: Float = Float(m.glow)
        if content.kind == .model && content.useModelMaterials && part.material < mesh.materials.count {
            let own: Geometry3D.ModelMaterial = mesh.materials[part.material]
            let texture: MTLTexture? = mesh.textures[part.material]
            let flags: Float = texture != nil ? 3 : 2
            return (Surface(color: own.color, params: SIMD4<Float>(own.metallic, own.roughness, glow, flags)), texture)
        }
        let useSide: Bool = content.kind == .text && part.material == 1
        let color: RGBA = useSide ? m.sideColor : m.color
        let flags: Float = content.kind == .model ? 2 : 0
        let params = SIMD4<Float>(Float(m.metallic), Float(m.roughness), glow, flags)
        return (Surface(color: Renderer3D.linear(color), params: params), nil)
    }

    private func passDescriptor(target: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        if sampleCount > 1, let msaa = msaa {
            pass.colorAttachments[0].texture = msaa
            pass.colorAttachments[0].resolveTexture = target
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        return pass
    }

    // MARK: 描画先

    private func prepareTargets(width: Int, height: Int) -> Bool {
        if width == targetWidth && height == targetHeight && pool != nil && depth != nil { return true }
        targetWidth = width
        targetHeight = height
        pool = Renderer3D.makePool(width: width, height: height)
        msaa = sampleCount > 1 ? makeTransient(.bgra8Unorm_srgb, width: width, height: height) : nil
        depth = makeTransient(.depth32Float, width: width, height: height)
        return pool != nil && depth != nil && (sampleCount == 1 || msaa != nil)
    }

    /// 描くあいだだけ使う絵（iPad ではメモリを使わない memoryless を先に試す）。
    private func makeTransient(_ format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = .renderTarget
        if sampleCount > 1 {
            d.textureType = .type2DMultisample
            d.sampleCount = sampleCount
        }
        #if os(iOS)
        d.storageMode = .memoryless
        if let texture = device.makeTexture(descriptor: d) { return texture }
        #endif
        d.storageMode = .private
        return device.makeTexture(descriptor: d)
    }

    static func makePool(width: Int, height: Int) -> CVPixelBufferPool? {
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private func makePixelBuffer() -> CVPixelBuffer? {
        guard let pool = pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func metalTexture(for buffer: CVPixelBuffer) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        var usage: [String: Any] = [:]
        usage[kCVMetalTextureUsage as String] = NSNumber(value: MTLTextureUsage([.renderTarget, .shaderRead]).rawValue)
        var result: CVMetalTexture?
        let status: CVReturn = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, usage as CFDictionary,
                                                                         .bgra8Unorm_srgb, CVPixelBufferGetWidth(buffer),
                                                                         CVPixelBufferGetHeight(buffer), 0, &result)
        return status == kCVReturnSuccess ? result : nil
    }

    // MARK: 形

    private func gpuMesh(_ content: Object3DContent, model: ModelSource?) -> GPUMesh? {
        let key: String = content.kind == .model ? "model|" + (model?.key ?? "") : content.geometryKey
        if let hit = cache[key] {
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            return hit
        }
        if failed.contains(key) { return nil }
        var data = MeshData()
        var materials: [Geometry3D.ModelMaterial] = []
        switch content.kind {
        case .text:
            data = Geometry3D.textMesh(content)
        case .model:
            guard let source = model, let loaded = try? Geometry3D.loadModel(url: source.url) else {
                failed.insert(key)
                return nil
            }
            data = loaded.mesh
            materials = loaded.materials
        case .cube, .sphere, .cylinder, .cone, .torus:
            data = Primitives.mesh(content.kind)
        }
        guard let mesh = makeGPUMesh(data, materials: materials) else {
            failed.insert(key)
            return nil
        }
        cache[key] = mesh
        cacheOrder.append(key)
        while cacheOrder.count > Renderer3D.cacheLimit {
            let old: String = cacheOrder.removeFirst()
            cache[old] = nil
        }
        return mesh
    }

    private func makeGPUMesh(_ data: MeshData, materials: [Geometry3D.ModelMaterial]) -> GPUMesh? {
        if data.isEmpty { return nil }
        let vectorStride: Int = MemoryLayout<SIMD3<Float>>.stride
        let uvStride: Int = MemoryLayout<SIMD2<Float>>.stride
        guard let positions = device.makeBuffer(bytes: data.positions, length: data.positions.count * vectorStride, options: .storageModeShared),
              let normals = device.makeBuffer(bytes: data.normals, length: data.normals.count * vectorStride, options: .storageModeShared),
              let uvs = device.makeBuffer(bytes: data.uvs, length: data.uvs.count * uvStride, options: .storageModeShared),
              let indices = device.makeBuffer(bytes: data.indices, length: data.indices.count * MemoryLayout<UInt32>.stride,
                                              options: .storageModeShared) else { return nil }
        var textures: [MTLTexture?] = []
        let loader = MTKTextureLoader(device: device)
        var options: [MTKTextureLoader.Option: Any] = [:]
        options[.SRGB] = true
        options[.generateMipmaps] = true
        options[.textureStorageMode] = NSNumber(value: MTLStorageMode.private.rawValue)
        for material in materials {
            if let texture = material.texture {
                textures.append(try? loader.newTexture(texture: texture, options: options))
            } else if let url = material.textureURL {
                textures.append(try? loader.newTexture(URL: url, options: options))
            } else {
                textures.append(nil)
            }
        }
        return GPUMesh(positions: positions, normals: normals, uvs: uvs, indices: indices, parts: data.parts,
                       materials: materials, textures: textures)
    }

    // MARK: 行列と光

    private static func uniforms(content: Object3DContent, pose: Pose, aspect: Float) -> Uniforms {
        let fov: Float = Float(Num.clamp(content.fieldOfView, 15, 90) * Double.pi / 180)
        let distance: Float = 5
        let visibleHeight: Float = 2 * distance * tan(fov / 2)
        let visibleWidth: Float = visibleHeight * aspect
        let size: Float = Float(max(0.001, content.size * pose.scale)) * visibleHeight
        let x: Float = Float(pose.positionX) * visibleWidth
        let y: Float = Float(-pose.positionY) * visibleHeight
        let z: Float = Float(Num.clamp(pose.positionZ, -4, 1.2)) * visibleHeight
        let rx: Float = Float(pose.rotationX * Double.pi / 180)
        let ry: Float = Float(pose.rotationY * Double.pi / 180)
        let rz: Float = Float(-pose.rotationZ * Double.pi / 180)
        let rotation: simd_float4x4 = Renderer3D.rotation(rz, SIMD3<Float>(0, 0, 1))
            * Renderer3D.rotation(ry, SIMD3<Float>(0, 1, 0)) * Renderer3D.rotation(rx, SIMD3<Float>(1, 0, 0))
        let model: simd_float4x4 = Renderer3D.translation(SIMD3<Float>(x, y, z)) * rotation * Renderer3D.scaling(size)
        let view: simd_float4x4 = Renderer3D.translation(SIMD3<Float>(0, 0, -distance))
        let projection: simd_float4x4 = Renderer3D.perspective(fov: fov, aspect: aspect, near: 0.1, far: 100)
        let c0: SIMD4<Float> = model.columns.0
        let c1: SIMD4<Float> = model.columns.1
        let c2: SIMD4<Float> = model.columns.2
        let upper = simd_float3x3(SIMD3<Float>(c0.x, c0.y, c0.z), SIMD3<Float>(c1.x, c1.y, c1.z), SIMD3<Float>(c2.x, c2.y, c2.z))
        return Uniforms(model: model, viewProjection: projection * view, normalMatrix: upper.inverse.transpose,
                        camera: SIMD4<Float>(0, 0, distance, 1))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m: simd_float4x4 = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func scaling(_ s: Float) -> simd_float4x4 {
        return simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
    }

    static func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
        return simd_float4x4(simd_quatf(angle: angle, axis: axis))
    }

    static func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let ys: Float = 1 / tan(fov / 2)
        let xs: Float = ys / aspect
        let zs: Float = far / (near - far)
        return simd_float4x4(columns: (SIMD4<Float>(xs, 0, 0, 0), SIMD4<Float>(0, ys, 0, 0),
                                       SIMD4<Float>(0, 0, zs, -1), SIMD4<Float>(0, 0, zs * near, 0)))
    }

    /// sRGB の色を光の計算用（リニア）にする。
    static func linear(_ c: RGBA) -> SIMD4<Float> {
        return SIMD4<Float>(Float(pow(c.r, 2.2)), Float(pow(c.g, 2.2)), Float(pow(c.b, 2.2)), Float(c.a))
    }

    private static func light(_ dx: Float, _ dy: Float, _ dz: Float, _ r: Float, _ g: Float, _ b: Float, _ power: Float) -> Light {
        return Light(direction: SIMD4<Float>(dx, dy, dz, 0), color: SIMD4<Float>(r * power, g * power, b * power, 1))
    }

    private static func ambient(_ r: Float, _ g: Float, _ b: Float) -> SIMD4<Float> {
        return SIMD4<Float>(r, g, b, 1)
    }

    /// 照明のプリセット（キー・フィル・リムの 3 灯と、上下の環境光）。
    private static func lights(_ preset: Lighting3D) -> Lights {
        switch preset {
        case .studio:
            return Lights(key: light(-0.5, 0.65, 0.6, 1, 0.98, 0.95, 2.4), fill: light(0.65, 0.2, 0.55, 0.65, 0.72, 0.85, 0.9),
                          rim: light(0.15, 0.55, -0.85, 1, 1, 1, 1.8), ambientTop: ambient(0.30, 0.32, 0.36), ambientBottom: ambient(0.08, 0.08, 0.09))
        case .soft:
            return Lights(key: light(-0.3, 0.7, 0.75, 1, 0.97, 0.92, 1.5), fill: light(0.6, 0.3, 0.7, 0.85, 0.9, 1, 1.0),
                          rim: light(0, 0.5, -0.85, 1, 1, 1, 0.6), ambientTop: ambient(0.55, 0.56, 0.6), ambientBottom: ambient(0.3, 0.3, 0.32))
        case .dramatic:
            return Lights(key: light(-0.85, 0.45, 0.3, 1, 0.9, 0.8, 3.0), fill: light(0.7, 0.1, 0.6, 0.6, 0.7, 1, 0.15),
                          rim: light(0.5, 0.4, -0.8, 0.7, 0.8, 1, 2.2), ambientTop: ambient(0.05, 0.05, 0.06), ambientBottom: ambient(0.02, 0.02, 0.02))
        case .sunset:
            return Lights(key: light(-0.7, 0.25, 0.65, 1, 0.55, 0.28, 2.6), fill: light(0.6, 0.3, 0.6, 0.55, 0.35, 0.8, 0.8),
                          rim: light(0.3, 0.6, -0.8, 1, 0.45, 0.55, 1.6), ambientTop: ambient(0.35, 0.22, 0.30), ambientBottom: ambient(0.12, 0.06, 0.08))
        case .neon:
            return Lights(key: light(-0.7, 0.3, 0.6, 1, 0.15, 0.75, 2.2), fill: light(0.75, 0.2, 0.6, 0.1, 0.85, 1, 2.0),
                          rim: light(0, 0.6, -0.8, 0.45, 0.3, 1, 2.0), ambientTop: ambient(0.12, 0.06, 0.2), ambientBottom: ambient(0.02, 0.02, 0.06))
        case .backlit:
            return Lights(key: light(-0.3, 0.3, 0.9, 1, 1, 1, 0.5), fill: light(0.5, 0.1, 0.5, 0.8, 0.85, 1, 0.3),
                          rim: light(0, 0.3, -1, 1, 0.95, 0.9, 3.5), ambientTop: ambient(0.12, 0.12, 0.14), ambientBottom: ambient(0.05, 0.05, 0.05))
        }
    }

    // MARK: シェーダー

    static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float3 position [[attribute(0)]];
        float3 normal [[attribute(1)]];
        float2 uv [[attribute(2)]];
    };

    struct Uniforms {
        float4x4 model;
        float4x4 viewProjection;
        float3x3 normalMatrix;
        float4 camera;
    };

    struct Light {
        float4 direction;
        float4 color;
    };

    struct Lights {
        Light lights[3];
        float4 ambientTop;
        float4 ambientBottom;
    };

    struct Surface {
        float4 color;
        float4 params;
    };

    struct VertexOut {
        float4 position [[position]];
        float3 world;
        float3 normal;
        float2 uv;
    };

    vertex VertexOut vertex3d(VertexIn in [[stage_in]], constant Uniforms &u [[buffer(3)]]) {
        VertexOut out;
        float4 world = u.model * float4(in.position, 1.0);
        out.position = u.viewProjection * world;
        out.world = world.xyz;
        out.normal = u.normalMatrix * in.normal;
        out.uv = in.uv;
        return out;
    }

    static float3 environment(float3 dir, constant Lights &l) {
        float t = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
        float3 sky = mix(l.ambientBottom.rgb, l.ambientTop.rgb, t);
        float band = smoothstep(0.55, 0.9, dir.y) * 0.8 + (1.0 - smoothstep(0.0, 0.3, abs(dir.y + 0.05))) * 0.35;
        return sky * 2.2 + float3(band);
    }

    fragment float4 fragment3d(VertexOut in [[stage_in]],
                               constant Uniforms &u [[buffer(3)]],
                               constant Lights &l [[buffer(4)]],
                               constant Surface &m [[buffer(5)]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
        float3 n = normalize(in.normal);
        float3 v = normalize(u.camera.xyz - in.world);
        float flags = m.params.w;
        if (flags >= 2.0 && dot(n, v) < 0.0) {
            n = -n;
        }
        float4 base = m.color;
        if (fmod(flags, 2.0) >= 1.0) {
            base *= tex.sample(smp, float2(in.uv.x, 1.0 - in.uv.y));
        }
        float metallic = clamp(m.params.x, 0.0, 1.0);
        float rough = clamp(m.params.y, 0.03, 1.0);
        float glow = m.params.z;
        float3 albedo = base.rgb;
        float3 diffuse = albedo * (1.0 - metallic);
        float3 f0 = mix(float3(0.04), albedo, metallic);
        float shininess = exp2(10.0 * (1.0 - rough) + 1.0);
        float ndv = max(dot(n, v), 0.0);
        float3 fresnel = f0 + (1.0 - f0) * pow(1.0 - ndv, 5.0) * (1.0 - rough);
        float hemi = n.y * 0.5 + 0.5;
        float3 color = diffuse * mix(l.ambientBottom.rgb, l.ambientTop.rgb, hemi);
        for (int i = 0; i < 3; i++) {
            float3 ld = normalize(l.lights[i].direction.xyz);
            float ndl = max(dot(n, ld), 0.0);
            float3 h = normalize(ld + v);
            float spec = pow(max(dot(n, h), 0.0), shininess) * (shininess + 2.0) / 8.0;
            color += l.lights[i].color.rgb * ndl * (diffuse + fresnel * spec);
        }
        float3 r = reflect(-v, n);
        color += environment(r, l) * fresnel * (1.0 - rough * 0.85);
        color += albedo * glow * 1.2;
        return float4(saturate(color) * base.a, base.a);
    }
    """
}
#endif
