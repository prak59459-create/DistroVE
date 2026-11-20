#if canImport(Vision) && canImport(Metal) && canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

/// オプティカルフローでコマの間を作る（Q99: なめらかなスロー）。
/// 前後 2 コマの動きを行き（A→B）と帰り（B→A）の両方で Vision に求めさせ、間の時刻の絵を A と B の両方から寄せて混ぜる。
/// 行きと帰りが食い違う所（物の陰になって見えなくなる所）は、見えている側の絵を重く使う。
final class FrameInterpolator: @unchecked Sendable {
    static let shared: FrameInterpolator? = FrameInterpolator()

    /// Vision の出す動きの向きと単位。最初に動きのある 2 コマで確かめる（OS の版で変わっても困らないように）。
    struct FlowConvention: Equatable {
        var sign: Float
        /// true なら画面に対する割合、false なら画素
        var normalized: Bool
    }

    private struct Params {
        var t: Float
        var sigma: Float
        var flowScale: SIMD2<Float>
    }

    /// 動きを求めるときの絵の長い辺（大きいほど細かいが遅い）
    static let flowSide: Int = 960

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let context: CIContext
    private var textureCache: CVMetalTextureCache?
    private var smallPool: CVPixelBufferPool?
    private var smallSize: (Int, Int) = (0, 0)
    private let lock = NSLock()

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: FrameInterpolator.shaderSource, options: nil),
              let function = library.makeFunction(name: "interpolate"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: 書き出し

    /// url の range の部分を factor 倍のコマ数にして output（MOV）に書く。output の 0 秒が range.start に当たる。
    func interpolate(url: URL, range: TimeRange, factor: Int, accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy,
                     output: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EngineError.unreadable("映像がありません") }
        let natural: CGSize = try await track.load(.naturalSize)
        let transform: CGAffineTransform = try await track.load(.preferredTransform)
        let nominal: Float = try await track.load(.nominalFrameRate)
        let fps: Double = nominal > 0 ? Double(nominal) : 30
        let width: Int = max(2, Int(natural.width) - Int(natural.width) % 2)
        let height: Int = max(2, Int(natural.height) - Int(natural.height) % 2)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range.cmTimeRange
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: FrameInterpolator.pixelAttributes(width: nil, height: nil))
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw EngineError.unreadable("映像を読めません") }
        reader.add(readerOutput)
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let settings: [String: Any] = FrameInterpolator.writerSettings(width: width, height: height, fps: fps * Double(factor))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: FrameInterpolator.pixelAttributes(width: width, height: height))
        guard writer.canAdd(input) else { throw EngineError.exportFailed("なめらかスローを書き出せません") }
        writer.add(input)
        guard reader.startReading() else { throw EngineError.unreadable(reader.error?.localizedDescription ?? "読み込みを始められません") }
        guard writer.startWriting() else { throw EngineError.exportFailed(writer.error?.localizedDescription ?? "書き込みを始められません") }
        let start: CMTime = range.start.cmTime
        writer.startSession(atSourceTime: start)
        var sink = FrameSink(input: input, adaptor: adaptor, start: start)
        var previous: CVPixelBuffer?
        var previousTime: CMTime = .invalid
        var convention: FlowConvention?
        var done: Int = 0
        let expected: Int = max(1, Int(range.duration.seconds * fps))
        while let sample = readerOutput.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                writer.cancelWriting()
                throw EngineError.cancelled
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time: CMTime = CMSampleBufferGetPresentationTimeStamp(sample)
            if let a = previous {
                let middle: [(CVPixelBuffer, CMTime)] = try between(a, buffer, from: previousTime, to: time, factor: factor,
                                                                   accuracy: accuracy, convention: &convention, pool: adaptor.pixelBufferPool)
                for (frame, at) in middle {
                    try await sink.append(frame, at)
                }
            }
            try await sink.append(buffer, time)
            previous = buffer
            previousTime = time
            done += 1
            progress?(min(1, Double(done) / Double(expected)))
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw EngineError.unreadable(reader.error?.localizedDescription ?? "読み込みエラー")
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "なめらかスローの保存に失敗しました")
        }
    }

    /// 書き込み先。時刻が戻るコマや範囲より前のコマは飛ばす。
    private struct FrameSink {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let start: CMTime
        var last: CMTime = .invalid

        init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, start: CMTime) {
            self.input = input
            self.adaptor = adaptor
            self.start = start
        }

        mutating func append(_ buffer: CVPixelBuffer, _ time: CMTime) async throws {
            if CMTimeCompare(time, start) < 0 { return }
            if last.isValid && CMTimeCompare(time, last) <= 0 { return }
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !adaptor.append(buffer, withPresentationTime: time) {
                throw EngineError.exportFailed("なめらかスローの書き出しに失敗しました")
            }
            last = time
        }
    }

    // MARK: 2 コマの間

    /// A と B の間に factor - 1 枚を作る。
    private func between(_ a: CVPixelBuffer, _ b: CVPixelBuffer, from ta: CMTime, to tb: CMTime, factor: Int,
                         accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy, convention: inout FlowConvention?,
                         pool: CVPixelBufferPool?) throws -> [(CVPixelBuffer, CMTime)] {
        guard factor > 1, let pool = pool else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard let smallA = downscaled(a), let smallB = downscaled(b) else { return [] }
        let forward: FlowField = try flowField(from: smallA, to: smallB, accuracy: accuracy)
        let backward: FlowField = try flowField(from: smallB, to: smallA, accuracy: accuracy)
        if method == .builtin {
            // 自前の推定は「A の各点が B で動いた先（画素）」と決まっている
            convention = FlowConvention(sign: 1, normalized: false)
        } else if convention == nil {
            convention = FrameInterpolator.calibrate(a: smallA, b: smallB, flow: forward)
        }
        let used: FlowConvention = convention ?? FlowConvention(sign: 1, normalized: false)
        guard let fab = flowTexture(forward), let fba = flowTexture(backward),
              let texA = metalTexture(a, write: false), let texB = metalTexture(b, write: false),
              let sourceA = CVMetalTextureGetTexture(texA), let sourceB = CVMetalTextureGetTexture(texB),
              let commands = queue.makeCommandBuffer() else { return [] }
        let flowWidth: Float = Float(forward.width)
        let flowHeight: Float = Float(forward.height)
        let scale: SIMD2<Float> = used.normalized ? SIMD2<Float>(used.sign, used.sign)
            : SIMD2<Float>(used.sign / flowWidth, used.sign / flowHeight)
        let sigma: Float = max(1, 2.5 * Float(CVPixelBufferGetHeight(a)) / 1080)
        var results: [(CVPixelBuffer, CMTime)] = []
        var keep: [CVMetalTexture] = [texA, texB]
        let delta: CMTime = CMTimeSubtract(tb, ta)
        for k in 1..<factor {
            let t: Float = Float(k) / Float(factor)
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
            guard let frame = made, let target = metalTexture(frame, write: true), let out = CVMetalTextureGetTexture(target) else { continue }
            keep.append(target)
            encode(commands, a: sourceA, b: sourceB, fab: fab, fba: fba, out: out,
                   params: Params(t: t, sigma: sigma, flowScale: scale))
            let at: CMTime = CMTimeAdd(ta, CMTimeMultiplyByFloat64(delta, multiplier: Float64(t)))
            results.append((frame, at))
        }
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(keep) {}
        return commands.status == .completed ? results : []
    }

    private func encode(_ commands: MTLCommandBuffer, a: MTLTexture, b: MTLTexture, fab: MTLTexture, fba: MTLTexture,
                        out: MTLTexture, params: Params) {
        guard let encoder = commands.makeComputeCommandEncoder() else { return }
        var p: Params = params
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(a, index: 0)
        encoder.setTexture(b, index: 1)
        encoder.setTexture(fab, index: 2)
        encoder.setTexture(fba, index: 3)
        encoder.setTexture(out, index: 4)
        encoder.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (out.width + 15) / 16, height: (out.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    // MARK: 動き（Vision）

    /// 動きの求め方。Vision の新しい版 → 古い版 → 自前（Lucas–Kanade）の順に試し、使えたものを続けて使う。
    enum FlowMethod: Equatable {
        case vision(revision: Int?)
        case builtin
    }

    /// 使えた求め方（1 回の書き出しのあいだ覚えておく）
    private(set) var method: FlowMethod?

    private func flowField(from a: CVPixelBuffer, to b: CVPixelBuffer, accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy) throws -> FlowField {
        let all: [FlowMethod] = [.vision(revision: nil), .vision(revision: VNGenerateOpticalFlowRequestRevision1), .builtin]
        // うまくいった求め方を先に。だめならほかも試す
        let order: [FlowMethod] = method.map { known in [known] + all.filter { $0 != known } } ?? all
        for candidate in order {
            switch candidate {
            case .vision(let revision):
                if let field = try? FrameInterpolator.visionFlow(from: a, to: b, accuracy: accuracy, revision: revision) {
                    method = candidate
                    return field
                }
            case .builtin:
                guard let grayA = FrameInterpolator.gray(a), let grayB = FrameInterpolator.gray(b) else { break }
                method = .builtin
                return OpticalFlowLK.flow(from: grayA, to: grayB)
            }
        }
        throw EngineError.unsupported("動きを解析できません")
    }

    /// handler の絵（from）と targeted の絵（to）の間の動き（Vision）。向きと単位は calibrate で確かめる。
    static func visionFlow(from a: CVPixelBuffer, to b: CVPixelBuffer, accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy,
                           revision: Int?) throws -> FlowField {
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: b, options: [:])
        if let r = revision { request.revision = r }
        request.computationAccuracy = accuracy
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: a, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { throw EngineError.unsupported("動きを解析できません") }
        return try FrameInterpolator.field(from: observation.pixelBuffer)
    }

    /// 2 成分の 32bit 浮動小数の絵を FlowField にする。
    static func field(from buffer: CVPixelBuffer) throws -> FlowField {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let reader = FlowReader(buffer) else { throw EngineError.unsupported("動きを読めません") }
        var vectors: [Float] = Array(repeating: 0, count: reader.width * reader.height * 2)
        for y in 0..<reader.height {
            for x in 0..<reader.width {
                let v: (Double, Double) = reader.value(Double(x), Double(y))
                vectors[(y * reader.width + x) * 2] = Float(v.0)
                vectors[(y * reader.width + x) * 2 + 1] = Float(v.1)
            }
        }
        return FlowField(width: reader.width, height: reader.height, vectors: vectors)
    }

    /// BGRA の絵の明るさ（自前の推定用）。
    static func gray(_ buffer: CVPixelBuffer) -> GrayImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let reader = LumaReader(buffer) else { return nil }
        var pixels: [Float] = Array(repeating: 0, count: reader.width * reader.height)
        for y in 0..<reader.height {
            for x in 0..<reader.width {
                pixels[y * reader.width + x] = Float(reader.value(Double(x), Double(y)))
            }
        }
        return GrayImage(width: reader.width, height: reader.height, pixels: pixels)
    }

    /// 向き（±）と単位（画素・割合）の 4 通りのうち、A(x) ≈ B(x + F(x)) をいちばんよく満たすもの。動きが小さすぎれば nil。
    static func calibrate(a: CVPixelBuffer, b: CVPixelBuffer, flow: FlowField) -> FlowConvention? {
        let candidates: [FlowConvention] = [FlowConvention(sign: 1, normalized: false), FlowConvention(sign: -1, normalized: false),
                                            FlowConvention(sign: 1, normalized: true), FlowConvention(sign: -1, normalized: true)]
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let imageA = LumaReader(a), let imageB = LumaReader(b) else { return nil }
        let field: FlowField = flow
        var errors: [Double] = Array(repeating: 0, count: candidates.count)
        var baseline: Double = 0
        let steps: Int = 40
        for j in 1..<steps {
            for i in 1..<steps {
                let x: Double = Double(imageA.width * i) / Double(steps)
                let y: Double = Double(imageA.height * j) / Double(steps)
                let lumaA: Double = imageA.value(x, y)
                baseline += abs(lumaA - imageB.value(x, y))
                let sample: (dx: Float, dy: Float) = field.at(Int(x * Double(field.width) / Double(imageA.width)),
                                                            Int(y * Double(field.height) / Double(imageA.height)))
                let f: (Double, Double) = (Double(sample.dx), Double(sample.dy))
                for (k, c) in candidates.enumerated() {
                    let dx: Double = c.normalized ? f.0 * Double(imageA.width) : f.0 * Double(imageA.width) / Double(field.width)
                    let dy: Double = c.normalized ? f.1 * Double(imageA.height) : f.1 * Double(imageA.height) / Double(field.height)
                    let s: Double = Double(c.sign)
                    errors[k] += abs(lumaA - imageB.value(x + s * dx, y + s * dy))
                }
            }
        }
        var best: Int = 0
        for k in 1..<errors.count where errors[k] < errors[best] {
            best = k
        }
        return errors[best] < baseline * 0.85 ? candidates[best] : nil
    }

    // MARK: 絵の用意

    /// 動きを求める用の小さい絵（長い辺を flowSide まで）。
    private func downscaled(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let w: Int = CVPixelBufferGetWidth(buffer)
        let h: Int = CVPixelBufferGetHeight(buffer)
        let ratio: Double = min(1, Double(FrameInterpolator.flowSide) / Double(max(w, h)))
        if ratio >= 0.999 { return buffer }
        let sw: Int = max(2, Int(Double(w) * ratio) / 2 * 2)
        let sh: Int = max(2, Int(Double(h) * ratio) / 2 * 2)
        if smallPool == nil || smallSize != (sw, sh) {
            var attributes: [String: Any] = FrameInterpolator.pixelAttributes(width: sw, height: sh)
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            smallPool = pool
            smallSize = (sw, sh)
        }
        guard let pool = smallPool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        guard let small = made else { return nil }
        let scale = CGAffineTransform(scaleX: CGFloat(sw) / CGFloat(w), y: CGFloat(sh) / CGFloat(h))
        let image: CIImage = CIImage(cvPixelBuffer: buffer).transformed(by: scale)
        context.render(image, to: small, bounds: CGRect(x: 0, y: 0, width: sw, height: sh), colorSpace: nil)
        return small
    }

    private func flowTexture(_ field: FlowField) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: field.width, height: field.height, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        field.vectors.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, field.width, field.height), mipmapLevel: 0, withBytes: base,
                            bytesPerRow: field.width * 2 * MemoryLayout<Float>.size)
        }
        return texture
    }

    private func metalTexture(_ buffer: CVPixelBuffer, write: Bool) -> CVMetalTexture? {
        guard let cache = textureCache else { return nil }
        let usage: MTLTextureUsage = write ? [.shaderWrite, .shaderRead] : [.shaderRead]
        var attributes: [String: Any] = [:]
        attributes[kCVMetalTextureUsage as String] = NSNumber(value: usage.rawValue)
        var result: CVMetalTexture?
        let status: CVReturn = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, attributes as CFDictionary,
                                                                         .bgra8Unorm, CVPixelBufferGetWidth(buffer),
                                                                         CVPixelBufferGetHeight(buffer), 0, &result)
        return status == kCVReturnSuccess ? result : nil
    }

    static func pixelAttributes(width: Int?, height: Int?) -> [String: Any] {
        var values: [String: Any] = [:]
        values[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        values[kCVPixelBufferMetalCompatibilityKey as String] = true
        values[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        if let w = width, let h = height {
            values[kCVPixelBufferWidthKey as String] = w
            values[kCVPixelBufferHeightKey as String] = h
        }
        return values
    }

    static func writerSettings(width: Int, height: Int, fps: Double) -> [String: Any] {
        let bits: Double = Double(width * height) * fps * 0.06
        var compression: [String: Any] = [:]
        compression[AVVideoAverageBitRateKey] = Int(min(160_000_000, max(4_000_000, bits)))
        compression[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded())
        var values: [String: Any] = [:]
        values[AVVideoCodecKey] = AVVideoCodecType.h264
        values[AVVideoWidthKey] = width
        values[AVVideoHeightKey] = height
        values[AVVideoCompressionPropertiesKey] = compression
        return values
    }

    // MARK: シェーダー

    static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float t;
        float sigma;
        float2 flowScale;
    };

    static float2 flowAt(texture2d<float, access::read> f, float2 uv) {
        float2 size = float2(f.get_width(), f.get_height());
        float2 p = clamp(uv * size - 0.5, float2(0.0), size - 1.0);
        float2 base = floor(p);
        uint2 i0 = uint2(base);
        uint2 i1 = uint2(min(base + 1.0, size - 1.0));
        float2 w = p - base;
        float2 a = f.read(uint2(i0.x, i0.y)).xy;
        float2 b = f.read(uint2(i1.x, i0.y)).xy;
        float2 c = f.read(uint2(i0.x, i1.y)).xy;
        float2 d = f.read(uint2(i1.x, i1.y)).xy;
        return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
    }

    kernel void interpolate(texture2d<float, access::sample> a [[texture(0)]],
                            texture2d<float, access::sample> b [[texture(1)]],
                            texture2d<float, access::read> fab [[texture(2)]],
                            texture2d<float, access::read> fba [[texture(3)]],
                            texture2d<float, access::write> out [[texture(4)]],
                            constant Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        uint w = out.get_width();
        uint h = out.get_height();
        if (gid.x >= w || gid.y >= h) {
            return;
        }
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 size = float2(w, h);
        float2 uv = (float2(gid) + 0.5) / size;
        float t = p.t;
        float2 f01 = flowAt(fab, uv) * p.flowScale;
        float2 f10 = flowAt(fba, uv) * p.flowScale;
        float2 ft0 = -(1.0 - t) * t * f01 + t * t * f10;
        float2 ft1 = (1.0 - t) * (1.0 - t) * f01 - t * (1.0 - t) * f10;
        float2 q0 = uv + ft0;
        float2 q1 = uv + ft1;
        float2 g01 = flowAt(fab, q0) * p.flowScale;
        float2 back0 = flowAt(fba, q0 + g01) * p.flowScale;
        float2 g10 = flowAt(fba, q1) * p.flowScale;
        float2 back1 = flowAt(fab, q1 + g10) * p.flowScale;
        float e0 = length((g01 + back0) * size);
        float e1 = length((g10 + back1) * size);
        float s2 = p.sigma * p.sigma;
        float v0 = exp(-(e0 * e0) / s2) + 0.02;
        float v1 = exp(-(e1 * e1) / s2) + 0.02;
        float w0 = (1.0 - t) * v0;
        float w1 = t * v1;
        float4 c0 = a.sample(s, q0);
        float4 c1 = b.sample(s, q1);
        out.write((c0 * w0 + c1 * w1) / (w0 + w1), gid);
    }
    """
}

extension DeviceTier {
    /// オプティカルフローの細かさ（Q81: 端末に合わせる）。
    var flowAccuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy {
        switch profile.flowAccuracy {
        case 0: return .low
        case 1: return .medium
        case 2: return .high
        default: return .veryHigh
        }
    }
}

/// BGRA の絵の明るさを読む（calibrate 用。最も近い画素）。
private struct LumaReader {
    let base: UnsafeMutablePointer<UInt8>
    let bytesPerRow: Int
    let width: Int
    let height: Int

    init?(_ buffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        base = address.assumingMemoryBound(to: UInt8.self)
        bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
    }

    func value(_ x: Double, _ y: Double) -> Double {
        let ix: Int = max(0, min(width - 1, Int(x)))
        let iy: Int = max(0, min(height - 1, Int(y)))
        let p: Int = iy * bytesPerRow + ix * 4
        let blue: Double = Double(base[p])
        let green: Double = Double(base[p + 1])
        let red: Double = Double(base[p + 2])
        return 0.114 * blue + 0.587 * green + 0.299 * red
    }
}

/// 動き（2 成分の 32bit 浮動小数）を読む。
private struct FlowReader {
    let base: UnsafeMutableRawPointer
    let bytesPerRow: Int
    let width: Int
    let height: Int

    init?(_ buffer: CVPixelBuffer) {
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        base = address
        bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
    }

    func value(_ x: Double, _ y: Double) -> (Double, Double) {
        let ix: Int = max(0, min(width - 1, Int(x)))
        let iy: Int = max(0, min(height - 1, Int(y)))
        let pointer: UnsafeMutablePointer<Float> = (base + iy * bytesPerRow + ix * 8).assumingMemoryBound(to: Float.self)
        return (Double(pointer[0]), Double(pointer[1]))
    }
}
#endif
