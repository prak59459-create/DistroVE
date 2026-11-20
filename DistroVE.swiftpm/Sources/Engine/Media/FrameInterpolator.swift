#if canImport(Vision) && canImport(Metal) && canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal
import Vision

/// 速さを変えたクリップのコマを作る（Q99）。RetimePlan のとおり、タイムラインの 1 コマずつに素材のその時刻の絵を作ってファイルに書く。
/// - 光学フロー：前後 2 コマの動きを行き（A→B）と帰り（B→A）の両方で Vision に求めさせ、間の時刻の絵を A と B の両方から寄せて混ぜる。
///   行きと帰りが食い違う所（物の陰になって見えなくなる所）は、見えている側の絵を重く使う。
/// - コマの合成：前後 2 コマを時刻に応じた割合で重ねる。
/// - モーションブラー：シャッターの開いている間を細かく分けて作った絵を平均する（光学フローなら動きに沿って伸びる）。
/// - カット（場面の切り替わり）の前後では間を作らず、近いコマをそのまま使う。止まっている場面も計算を省く。
final class FrameInterpolator: @unchecked Sendable {
    static let shared: FrameInterpolator? = FrameInterpolator()

    /// Vision の出す動きの向きと単位。最初に動きのある 2 コマで確かめる（OS の版で変わっても困らないように）。
    struct FlowConvention: Equatable {
        var sign: Float
        /// true なら画面に対する割合、false なら画素
        var normalized: Bool
    }

    /// 動きの求め方。Vision の新しい版 → 古い版 → 自前（Lucas–Kanade）の順に試し、使えたものを続けて使う。
    enum FlowMethod: Equatable {
        case vision(revision: Int?)
        case builtin
    }

    /// 動きを求めるときの絵の長い辺（大きいほど細かいが遅い）
    static let flowSide: Int = 960

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let context: CIContext

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: FrameInterpolator.shaderSource, options: nil),
              let function = library.makeFunction(name: "retime"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    }

    /// plan のとおりにコマを作り、output（MOV）に書く。url は使う素材のファイル（逆再生なら逆順にしたファイル）。
    func render(plan: RetimePlan, url: URL, accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy,
                output: URL, progress: (@Sendable (Double) -> Void)?, isCancelled: (@Sendable () -> Bool)? = nil) async throws {
        let session = try await RetimeSession(owner: self, plan: plan, url: url, accuracy: accuracy, output: output)
        try await session.run(progress: progress, isCancelled: isCancelled)
    }

    /// スムースカット（Q99）：from の最後のコマから to の最初のコマへ、光学フローで変形させたコマを plan のとおりに作る。
    func renderMorph(plan: SmoothCutPlan, from aURL: URL, to bURL: URL, accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy,
                     output: URL, progress: (@Sendable (Double) -> Void)?, isCancelled: (@Sendable () -> Bool)? = nil) async throws {
        let first: CGImage = try await FrameInterpolator.still(at: plan.fromTime, url: aURL)
        let second: CGImage = try await FrameInterpolator.still(at: plan.toTime, url: bURL)
        let width: Int = max(2, first.width - first.width % 2)
        let height: Int = max(2, first.height - first.height % 2)
        guard let a = FrameInterpolator.pixelBuffer(from: first, width: width, height: height),
              let b = FrameInterpolator.pixelBuffer(from: second, width: width, height: height) else {
            throw EngineError.unreadable("つなぐコマを読めません")
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let textures = cache else { throw EngineError.unsupported("この端末ではコマを作れません") }
        // 動き（行きと帰り）。読めなければ重ねるだけにする
        var forward: MTLTexture?
        var backward: MTLTexture?
        var scale = SIMD2<Float>(0, 0)
        if let smallA = FrameInterpolator.downscaled(a, context: context), let smallB = FrameInterpolator.downscaled(b, context: context),
           let fab = FrameInterpolator.anyFlow(from: smallA, to: smallB, accuracy: accuracy),
           let fba = FrameInterpolator.anyFlow(from: smallB, to: smallA, accuracy: accuracy) {
            var found: FlowConvention?
            if fab.builtin {
                found = FlowConvention(sign: 1, normalized: false)
            } else {
                found = FrameInterpolator.learnedConvention.get() ?? FrameInterpolator.calibrate(a: smallA, b: smallB, flow: fab.field)
                if let known = found { FrameInterpolator.learnedConvention.set(known) }
            }
            // 動きを読み損ねたとき（大きすぎる動きなど）は、変形させずに重ねるだけにする
            if let convention = found, FrameInterpolator.flowHelps(a: smallA, b: smallB, flow: fab.field, convention: convention) {
                forward = FrameInterpolator.texture(fab.field, device: device)
                backward = FrameInterpolator.texture(fba.field, device: device)
                let fw: Float = Float(fab.field.width)
                let fh: Float = Float(fab.field.height)
                scale = convention.normalized ? SIMD2<Float>(convention.sign, convention.sign)
                    : SIMD2<Float>(convention.sign / fw, convention.sign / fh)
            }
        }
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var colors: [String: Any] = [:]
        colors[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_709_2
        colors[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_709_2
        colors[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_709_2
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: FrameInterpolator.writerSettings(width: width, height: height, fps: plan.fps, colors: colors))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: FrameInterpolator.pixelAttributes(width: width, height: height))
        guard writer.canAdd(input) else { throw EngineError.exportFailed("コマを書き出せません") }
        writer.add(input)
        guard writer.startWriting() else { throw EngineError.exportFailed(writer.error?.localizedDescription ?? "書き込みを始められません") }
        writer.startSession(atSourceTime: .zero)
        let sigma: Float = max(1, 2.5 * Float(height) / 1080)
        let half: Double = 0.5 / max(1, plan.fps)
        var last: Int64 = -1
        for (k, p) in plan.progress.enumerated() {
            if Task.isCancelled || isCancelled?() == true {
                writer.cancelWriting()
                throw EngineError.cancelled
            }
            guard let pool = adaptor.pixelBufferPool else { throw EngineError.exportFailed("描画先を確保できません") }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
            guard let target = made else { throw EngineError.exportFailed("描画先を確保できません") }
            var params = RetimeParams(t0: Float(p), t1: Float(p), weight: 1, sigma: sigma, flowScale: scale, samples: 1,
                                      mode: forward == nil ? 0 : 1, accumulate: 0, pad: 0)
            try encodeOnce(a: a, b: b, forward: forward, backward: backward, into: target, params: &params, cache: textures)
            let time: Double = k == 0 ? 0 : plan.outputTimes[k] - half
            var ticks: Int64 = Int64((time * Double(Time.timescale)).rounded())
            if ticks <= last { ticks = last + 1 }
            last = ticks
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { break }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if !adaptor.append(target, withPresentationTime: CMTime(value: ticks, timescale: CMTimeScale(Time.timescale))) {
                throw EngineError.exportFailed(writer.error?.localizedDescription ?? "コマの書き出しに失敗しました")
            }
            progress?(Double(k + 1) / Double(max(1, plan.progress.count)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: plan.duration.cmTime)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "コマの保存に失敗しました")
        }
    }

    /// 2 枚の絵から 1 枚を作る（変形の 1 コマ）。
    private func encodeOnce(a: CVPixelBuffer, b: CVPixelBuffer, forward: MTLTexture?, backward: MTLTexture?, into target: CVPixelBuffer,
                            params: inout RetimeParams, cache: CVMetalTextureCache) throws {
        guard let texA = FrameInterpolator.metalTexture(a, write: false, cache: cache), let texB = FrameInterpolator.metalTexture(b, write: false, cache: cache),
              let texOut = FrameInterpolator.metalTexture(target, write: true, cache: cache),
              let ta = CVMetalTextureGetTexture(texA), let tb = CVMetalTextureGetTexture(texB), let out = CVMetalTextureGetTexture(texOut),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else {
            throw EngineError.exportFailed("描画できません")
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        guard let filler = device.makeTexture(descriptor: d) else { throw EngineError.exportFailed("描画できません") }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(ta, index: 0)
        encoder.setTexture(tb, index: 1)
        encoder.setTexture(forward ?? filler, index: 2)
        encoder.setTexture(backward ?? filler, index: 3)
        encoder.setTexture(filler, index: 4)
        encoder.setTexture(out, index: 5)
        encoder.setBytes(&params, length: MemoryLayout<RetimeParams>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (out.width + 15) / 16, height: (out.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime([texA, texB, texOut]) {}
        if commands.status != .completed { throw EngineError.exportFailed("コマを作れませんでした") }
    }

    /// 動画の time 秒のコマ（回転を反映した向き）。
    static func still(at seconds: Double, url: URL) async throws -> CGImage {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600_000)
        return try await generator.image(at: time).image
    }

    /// CGImage を width × height の BGRA の絵に描く。
    static func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            pixelAttributes(width: width, height: height) as CFDictionary, &made)
        guard let buffer = made, let space = CGColorSpace(name: CGColorSpace.itur_709) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space, bitmapInfo: info) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// 動きを求める用の小さい絵（長い辺を flowSide まで）。
    static func downscaled(_ buffer: CVPixelBuffer, context: CIContext) -> CVPixelBuffer? {
        let w: Int = CVPixelBufferGetWidth(buffer)
        let h: Int = CVPixelBufferGetHeight(buffer)
        let ratio: Double = min(1, Double(flowSide) / Double(max(w, h)))
        if ratio >= 0.999 { return buffer }
        let sw: Int = max(2, Int(Double(w) * ratio) / 2 * 2)
        let sh: Int = max(2, Int(Double(h) * ratio) / 2 * 2)
        var made: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, sw, sh, kCVPixelFormatType_32BGRA, pixelAttributes(width: sw, height: sh) as CFDictionary, &made)
        guard let small = made else { return nil }
        let scale = CGAffineTransform(scaleX: CGFloat(sw) / CGFloat(w), y: CGFloat(sh) / CGFloat(h))
        context.render(CIImage(cvPixelBuffer: buffer).transformed(by: scale), to: small, bounds: CGRect(x: 0, y: 0, width: sw, height: sh), colorSpace: nil)
        return small
    }

    /// Vision（新しい版 → 古い版）、だめなら自前の推定で動きを求める。builtin は自前の推定を使ったか。
    static func anyFlow(from a: CVPixelBuffer, to b: CVPixelBuffer,
                        accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy) -> (field: FlowField, builtin: Bool)? {
        if let field = try? visionFlow(from: a, to: b, accuracy: accuracy, revision: nil) { return (field, false) }
        if let field = try? visionFlow(from: a, to: b, accuracy: accuracy, revision: VNGenerateOpticalFlowRequestRevision1) { return (field, false) }
        guard let grayA = gray(a), let grayB = gray(b) else { return nil }
        return (OpticalFlowLK.flow(from: grayA, to: grayB), true)
    }

    static func texture(_ field: FlowField, device: MTLDevice) -> MTLTexture? {
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

    static func metalTexture(_ buffer: CVPixelBuffer, write: Bool, cache: CVMetalTextureCache) -> CVMetalTexture? {
        let usage: MTLTextureUsage = write ? [.shaderWrite, .shaderRead] : [.shaderRead]
        var attributes: [String: Any] = [:]
        attributes[kCVMetalTextureUsage as String] = NSNumber(value: usage.rawValue)
        var result: CVMetalTexture?
        let status: CVReturn = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, buffer, attributes as CFDictionary,
                                                                         .bgra8Unorm, CVPixelBufferGetWidth(buffer),
                                                                         CVPixelBufferGetHeight(buffer), 0, &result)
        return status == kCVReturnSuccess ? result : nil
    }

    // MARK: 動き（Vision）

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

    /// カットの判定に使う縮小画像（BGRA の絵から、区画ごとに 8×8 点の明るさを平均する）。
    static func cutSignature(_ buffer: CVPixelBuffer) -> CutSignature? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let reader = LumaReader(buffer) else { return nil }
        let columns: Int = CutSignature.columns
        let rows: Int = CutSignature.rows
        let cellWidth: Double = Double(reader.width) / Double(columns)
        let cellHeight: Double = Double(reader.height) / Double(rows)
        var cells: [Float] = Array(repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                var sum: Double = 0
                for sy in 0..<8 {
                    let y: Double = (Double(row) + (Double(sy) + 0.5) / 8) * cellHeight
                    for sx in 0..<8 {
                        let x: Double = (Double(column) + (Double(sx) + 0.5) / 8) * cellWidth
                        sum += reader.value(x, y)
                    }
                }
                cells[row * columns + column] = Float(sum / 64)
            }
        }
        return CutSignature(thumbnail: cells)
    }

    /// 向き（±）と単位（画素・割合）の 4 通りのうち、A(x) ≈ B(x + F(x)) をいちばんよく満たすもの。動きが小さすぎれば nil。
    static func calibrate(a: CVPixelBuffer, b: CVPixelBuffer, flow: FlowField) -> FlowConvention? {
        guard let scores = conventionErrors(a: a, b: b, flow: flow) else { return nil }
        var best: Int?
        for (k, value) in scores.errors.enumerated() {
            guard let e = value else { continue }
            if let current = best, let known = scores.errors[current], known <= e { continue }
            best = k
        }
        guard let chosen = best, let error = scores.errors[chosen], error < scores.baseline * 0.85 else { return nil }
        return conventions[chosen]
    }

    /// 向き（±）と単位（画素・割合）の 4 通り。
    static let conventions: [FlowConvention] = [FlowConvention(sign: 1, normalized: false), FlowConvention(sign: -1, normalized: false),
                                                FlowConvention(sign: 1, normalized: true), FlowConvention(sign: -1, normalized: true)]

    /// 一度確かめた向きと単位（OS の版で決まるので、アプリを閉じるまで使い回す）
    static let learnedConvention = Locked<FlowConvention?>(nil)

    /// convention で A を動かすと B に十分近づくか（動きを読み損ねたときは間を作らず重ねるだけにするため）。
    static func flowHelps(a: CVPixelBuffer, b: CVPixelBuffer, flow: FlowField, convention: FlowConvention) -> Bool {
        guard let scores = conventionErrors(a: a, b: b, flow: flow),
              let index = conventions.firstIndex(of: convention), let error = scores.errors[index] else { return false }
        // 止まっている絵どうしなら、動かさなくても同じ
        if scores.baseline < 1 { return true }
        return error < scores.baseline * 0.8
    }

    /// 4 通りそれぞれで A(x) と B(x + F(x)) の差を足したもの（nil は、絵の外へ大きく飛び出す動きになるので候補にしない）と、動かさないときの差。
    /// 小さな物が無地の背景の上を動く絵では、単位を取り違えて「物がとても遠くへ飛ぶ」と読むと背景どうしが重なって差が小さく見えるので、飛び出す候補は除く。
    static func conventionErrors(a: CVPixelBuffer, b: CVPixelBuffer, flow: FlowField) -> (errors: [Double?], baseline: Double)? {
        CVPixelBufferLockBaseAddress(a, .readOnly)
        CVPixelBufferLockBaseAddress(b, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(a, .readOnly)
            CVPixelBufferUnlockBaseAddress(b, .readOnly)
        }
        guard let imageA = LumaReader(a), let imageB = LumaReader(b), flow.width > 0, flow.height > 0 else { return nil }
        let candidates: [FlowConvention] = conventions
        var errors: [Double] = Array(repeating: 0, count: candidates.count)
        var far: [Int] = Array(repeating: 0, count: candidates.count)
        var baseline: Double = 0
        let steps: Int = 40
        let limit: Double = 0.75 * Double(max(imageA.width, imageA.height))
        var points: Int = 0
        for j in 1..<steps {
            for i in 1..<steps {
                let x: Double = Double(imageA.width * i) / Double(steps)
                let y: Double = Double(imageA.height * j) / Double(steps)
                let lumaA: Double = imageA.value(x, y)
                baseline += abs(lumaA - imageB.value(x, y))
                points += 1
                let sample: (dx: Float, dy: Float) = flow.at(Int(x * Double(flow.width) / Double(imageA.width)),
                                                           Int(y * Double(flow.height) / Double(imageA.height)))
                let f: (Double, Double) = (Double(sample.dx), Double(sample.dy))
                for (k, c) in candidates.enumerated() {
                    let dx: Double = c.normalized ? f.0 * Double(imageA.width) : f.0 * Double(imageA.width) / Double(flow.width)
                    let dy: Double = c.normalized ? f.1 * Double(imageA.height) : f.1 * Double(imageA.height) / Double(flow.height)
                    if (dx * dx + dy * dy).squareRoot() > limit { far[k] += 1 }
                    let s: Double = Double(c.sign)
                    errors[k] += abs(lumaA - imageB.value(x + s * dx, y + s * dy))
                }
            }
        }
        let allowed: Int = max(1, points / 200)
        var result: [Double?] = []
        for k in 0..<candidates.count {
            result.append(far[k] > allowed ? nil : errors[k])
        }
        return (result, baseline)
    }

    /// 動きの大きさ（上位 5% の長さ。出力の画素で、2 コマの間にどれだけ動くか）。
    static func motionMagnitude(_ field: FlowField, convention: FlowConvention, width: Int, height: Int) -> Float {
        if field.width <= 0 || field.height <= 0 { return 0 }
        let sx: Float = convention.normalized ? Float(width) : Float(width) / Float(field.width)
        let sy: Float = convention.normalized ? Float(height) : Float(height) / Float(field.height)
        var lengths: [Float] = []
        lengths.reserveCapacity(field.width * field.height / 16 + 1)
        var y: Int = 0
        while y < field.height {
            var x: Int = 0
            while x < field.width {
                let v: (dx: Float, dy: Float) = field.at(x, y)
                let dx: Float = v.dx * sx
                let dy: Float = v.dy * sy
                let length: Float = (dx * dx + dy * dy).squareRoot()
                if length.isFinite { lengths.append(length) }
                x += 4
            }
            y += 4
        }
        if lengths.isEmpty { return 0 }
        lengths.sort()
        return lengths[min(lengths.count - 1, Int(Double(lengths.count) * 0.95))]
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

    /// 作るファイルの圧縮の設定。後でもう一度書き出すので、画質を落としすぎないよう多めのビットレートにする。
    static func writerSettings(width: Int, height: Int, fps: Double, colors: [String: Any]?) -> [String: Any] {
        let bits: Double = Double(width * height) * fps * 0.2
        var compression: [String: Any] = [:]
        compression[AVVideoAverageBitRateKey] = Int(min(200_000_000, max(8_000_000, bits)))
        compression[AVVideoExpectedSourceFrameRateKey] = Int(fps.rounded())
        compression[AVVideoMaxKeyFrameIntervalKey] = max(1, Int(fps.rounded()))
        compression[AVVideoAllowFrameReorderingKey] = false
        var values: [String: Any] = [:]
        // H.264 は 4096 を超える大きさを扱えない端末があるので、大きい絵は HEVC にする
        values[AVVideoCodecKey] = max(width, height) > 4096 ? AVVideoCodecType.hevc : AVVideoCodecType.h264
        values[AVVideoWidthKey] = width
        values[AVVideoHeightKey] = height
        values[AVVideoCompressionPropertiesKey] = compression
        if let c = colors { values[AVVideoColorPropertiesKey] = c }
        return values
    }

    /// 素材の色の扱い（色域・ガンマ・行列）を、作るファイルにも引き継ぐ（HDR の素材の色が変わらないように）。
    static func colorProperties(_ description: CMFormatDescription?) -> [String: Any]? {
        guard let format = description,
              let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] else { return nil }
        let primaries: [String] = [AVVideoColorPrimaries_ITU_R_709_2, AVVideoColorPrimaries_P3_D65, AVVideoColorPrimaries_ITU_R_2020]
        let transfers: [String] = [AVVideoTransferFunction_ITU_R_709_2, AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                                   AVVideoTransferFunction_ITU_R_2100_HLG]
        let matrices: [String] = [AVVideoYCbCrMatrix_ITU_R_709_2, AVVideoYCbCrMatrix_ITU_R_601_4, AVVideoYCbCrMatrix_ITU_R_2020]
        let p: String? = extensions[kCVImageBufferColorPrimariesKey as String] as? String
        let t: String? = extensions[kCVImageBufferTransferFunctionKey as String] as? String
        let m: String? = extensions[kCVImageBufferYCbCrMatrixKey as String] as? String
        guard let primary = p, let transfer = t, let matrix = m,
              primaries.contains(primary), transfers.contains(transfer), matrices.contains(matrix) else { return nil }
        var values: [String: Any] = [:]
        values[AVVideoColorPrimariesKey] = primary
        values[AVVideoTransferFunctionKey] = transfer
        values[AVVideoYCbCrMatrixKey] = matrix
        return values
    }

    // MARK: シェーダー

    static let shaderSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params {
        float t0;
        float t1;
        float weight;
        float sigma;
        float2 flowScale;
        int samples;
        int mode;
        int accumulate;
        int pad;
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

    static float4 warped(texture2d<float, access::sample> a, texture2d<float, access::sample> b,
                         texture2d<float, access::read> fab, texture2d<float, access::read> fba,
                         float2 uv, float2 size, float t, constant Params &p) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
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
        return (c0 * w0 + c1 * w1) / (w0 + w1);
    }

    kernel void retime(texture2d<float, access::sample> a [[texture(0)]],
                       texture2d<float, access::sample> b [[texture(1)]],
                       texture2d<float, access::read> fab [[texture(2)]],
                       texture2d<float, access::read> fba [[texture(3)]],
                       texture2d<float, access::read> accumulated [[texture(4)]],
                       texture2d<float, access::write> out [[texture(5)]],
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
        int n = max(p.samples, 1);
        float4 sum = float4(0.0);
        for (int j = 0; j < n; j++) {
            float t = n == 1 ? (p.t0 + p.t1) * 0.5 : p.t0 + (p.t1 - p.t0) * (float(j) + 0.5) / float(n);
            if (p.mode == 1) {
                sum += warped(a, b, fab, fba, uv, size, t, p);
            } else {
                sum += mix(a.sample(s, uv), b.sample(s, uv), t);
            }
        }
        float4 color = sum / float(n) * p.weight;
        if (p.accumulate != 0) {
            color += accumulated.read(gid);
        }
        out.write(color, gid);
    }
    """
}

/// 1 回のコマ作り（読み込み・書き込み・作業中の絵）。FrameInterpolator は同時にいくつ動いてもよいよう、状態はここに持つ。
/// シェーダーに渡す値（Metal 側の Params と同じ並び）
struct RetimeParams {
    var t0: Float
    var t1: Float
    var weight: Float
    var sigma: Float
    var flowScale: SIMD2<Float>
    var samples: Int32
    var mode: Int32
    var accumulate: Int32
    var pad: Int32
}

private final class RetimeSession {
    typealias Params = RetimeParams

    /// 読み込んだ素材の 1 コマ。縮小画像・カット判定用の情報・テクスチャは要るときに作る。
    final class SourceFrame {
        let buffer: CVPixelBuffer
        let time: Double
        var small: CVPixelBuffer?
        var signature: CutSignature?
        var texture: CVMetalTexture?

        init(buffer: CVPixelBuffer, time: Double) {
            self.buffer = buffer
            self.time = time
        }
    }

    /// 隣り合う 2 コマの関係（カットか、止まっているか、動き）。
    final class PairState {
        var cut: Bool = false
        var still: Bool = false
        var forward: MTLTexture?
        var backward: MTLTexture?
        var scale: SIMD2<Float> = SIMD2<Float>(0, 0)
        var motion: Float = 0
    }

    let owner: FrameInterpolator
    let plan: RetimePlan
    let accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy
    let reader: AVAssetReader
    let readerOutput: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int
    let height: Int
    let sigma: Float
    private var textureCache: CVMetalTextureCache?
    private var smallPool: CVPixelBufferPool?
    private var smallSize: (Int, Int) = (0, 0)
    private var accumulation: [MTLTexture] = []
    private var dummy: MTLTexture?
    private var window: [SourceFrame] = []
    /// window[0] が素材の何コマ目か
    private var baseIndex: Int = 0
    private var finished: Bool = false
    private var pairs: [Int: PairState] = [:]
    private var detector = SceneCutDetector()
    private var convention: FrameInterpolator.FlowConvention?
    private var method: FrameInterpolator.FlowMethod?

    init(owner: FrameInterpolator, plan: RetimePlan, url: URL, accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy,
         output: URL) async throws {
        self.owner = owner
        self.plan = plan
        self.accuracy = accuracy
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EngineError.unreadable("映像がありません") }
        let natural: CGSize = try await track.load(.naturalSize)
        let transform: CGAffineTransform = try await track.load(.preferredTransform)
        let descriptions: [CMFormatDescription] = try await track.load(.formatDescriptions)
        let nominal: Float = try await track.load(.nominalFrameRate)
        let sourceFrame: Double = 1 / Double(nominal > 0 ? nominal : 30)
        let outputWidth: Int = max(2, Int(natural.width) - Int(natural.width) % 2)
        let outputHeight: Int = max(2, Int(natural.height) - Int(natural.height) % 2)
        let assetReader = try AVAssetReader(asset: asset)
        // 前後に 2 コマずつ余分に読む（範囲の端でも前後のコマがそろうように）
        let readStart: Double = max(0, plan.sourceStart - 2 * sourceFrame)
        let readEnd: Double = plan.sourceEnd + 2 * sourceFrame
        assetReader.timeRange = CMTimeRange(start: CMTime(seconds: readStart, preferredTimescale: 600_000),
                                            end: CMTime(seconds: readEnd, preferredTimescale: 600_000))
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: FrameInterpolator.pixelAttributes(width: nil, height: nil))
        trackOutput.alwaysCopiesSampleData = false
        guard assetReader.canAdd(trackOutput) else { throw EngineError.unreadable("映像を読めません") }
        assetReader.add(trackOutput)
        try? FileManager.default.removeItem(at: output)
        let assetWriter = try AVAssetWriter(outputURL: output, fileType: .mov)
        let colors: [String: Any]? = FrameInterpolator.colorProperties(descriptions.first)
        let settings: [String: Any] = FrameInterpolator.writerSettings(width: outputWidth, height: outputHeight, fps: plan.fps, colors: colors)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        writerInput.transform = transform
        writerInput.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = FrameInterpolator.pixelAttributes(width: outputWidth, height: outputHeight)
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: attributes)
        guard assetWriter.canAdd(writerInput) else { throw EngineError.exportFailed("コマを書き出せません") }
        assetWriter.add(writerInput)
        width = outputWidth
        height = outputHeight
        sigma = max(1, 2.5 * Float(outputHeight) / 1080)
        reader = assetReader
        readerOutput = trackOutput
        writer = assetWriter
        input = writerInput
        adaptor = pixelAdaptor
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, owner.device, nil, &cache)
        textureCache = cache
    }

    func run(progress: (@Sendable (Double) -> Void)?, isCancelled: (@Sendable () -> Bool)?) async throws {
        guard reader.startReading() else { throw EngineError.unreadable(reader.error?.localizedDescription ?? "読み込みを始められません") }
        guard writer.startWriting() else { throw EngineError.exportFailed(writer.error?.localizedDescription ?? "書き込みを始められません") }
        writer.startSession(atSourceTime: .zero)
        let total: Int = max(1, plan.frames.count)
        let half: Double = 0.5 / max(1, plan.fps)
        var last: Int64 = -1
        for (k, frame) in plan.frames.enumerated() {
            if Task.isCancelled || isCancelled?() == true {
                reader.cancelReading()
                writer.cancelWriting()
                throw EngineError.cancelled
            }
            try fill(until: frame.exposureEnd)
            trim(before: frame.exposureStart)
            if window.isEmpty { break }
            let made: CVPixelBuffer = try compose(frame)
            // 合成は前のコマの表示時刻から次のコマまで同じ絵を出すので、コマの半分だけ前に置いて丸めの誤差でも隣のコマを拾わないようにする
            let time: Double = k == 0 ? 0 : frame.outputTime - half
            var ticks: Int64 = Int64((time * Double(Time.timescale)).rounded())
            if ticks <= last { ticks = last + 1 }
            last = ticks
            try await append(made, at: CMTime(value: ticks, timescale: CMTimeScale(Time.timescale)))
            progress?(Double(k + 1) / Double(total))
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw EngineError.unreadable(reader.error?.localizedDescription ?? "読み込みエラー")
        }
        reader.cancelReading()
        if last < 0 {
            writer.cancelWriting()
            throw EngineError.unreadable("素材のコマを読めませんでした")
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: plan.duration, preferredTimescale: CMTimeScale(Time.timescale)))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "コマの保存に失敗しました")
        }
    }

    private func append(_ buffer: CVPixelBuffer, at time: CMTime) async throws {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if !adaptor.append(buffer, withPresentationTime: time) {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "コマの書き出しに失敗しました")
        }
    }

    // MARK: 読み込み

    /// until より後のコマが手に入るまで読む（素材の終わりなら止める）。
    private func fill(until time: Double) throws {
        while !finished {
            if let lastFrame = window.last, lastFrame.time >= time { return }
            guard let sample = readerOutput.copyNextSampleBuffer() else {
                finished = true
                return
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let at: Double = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if !at.isFinite { continue }
            if let lastFrame = window.last, at <= lastFrame.time { continue }
            window.append(SourceFrame(buffer: buffer, time: at))
        }
    }

    /// time より前のコマは 1 つだけ残して捨てる。
    private func trim(before time: Double) {
        var removed: Int = 0
        while window.count - removed >= 2 && window[removed + 1].time <= time {
            removed += 1
        }
        if removed == 0 { return }
        window.removeFirst(removed)
        baseIndex += removed
        pairs = pairs.filter { $0.key >= baseIndex }
    }

    // MARK: 1 コマを作る

    private func compose(_ frame: RetimeFrame) throws -> CVPixelBuffer {
        var times: [Double] = []
        times.reserveCapacity(window.count)
        for f in window { times.append(f.time) }
        let parts: [ExposureSegment]
        if frame.hasExposure {
            parts = FrameTiming.segments(from: frame.exposureStart, to: frame.exposureEnd, in: times)
        } else {
            let p: FramePair = FrameTiming.pair(for: frame.sourceTime, in: times)
            parts = [ExposureSegment(first: p.first, second: p.second, from: p.position, to: p.position, weight: 1)]
        }
        // 素材のコマそのものなら、そのまま使う
        if parts.count == 1, parts[0].from == parts[0].to, parts[0].first == parts[0].second || parts[0].from <= 1e-6 {
            return window[parts[0].first].buffer
        }
        guard let pool = adaptor.pixelBufferPool else { throw EngineError.exportFailed("描画先を確保できません") }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        guard let target = made, let targetTexture = metalTexture(target, write: true),
              let out = CVMetalTextureGetTexture(targetTexture), let commands = owner.queue.makeCommandBuffer() else {
            throw EngineError.exportFailed("描画先を確保できません")
        }
        var keep: [CVMetalTexture] = [targetTexture]
        for (j, part) in parts.enumerated() {
            // 区間が 2 つ以上なら、作業用の絵 2 枚に交互に足し込み、最後の区間で書き出し先に書く
            var destination: MTLTexture = out
            if j < parts.count - 1 {
                destination = try accumulationTexture(j % 2)
            }
            var previous: MTLTexture? = nil
            if j > 0 {
                previous = try accumulationTexture((j - 1) % 2)
            }
            try encode(part, into: destination, accumulating: previous, commands: commands, keep: &keep)
        }
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(keep) {}
        if commands.status != .completed {
            throw EngineError.exportFailed("コマを作れませんでした")
        }
        CVBufferPropagateAttachments(window[parts[0].first].buffer, target)
        return target
    }

    /// 1 区間ぶんの絵を destination に書く（previous があれば足し込む）。
    private func encode(_ part: ExposureSegment, into destination: MTLTexture, accumulating previous: MTLTexture?,
                        commands: MTLCommandBuffer, keep: inout [CVMetalTexture]) throws {
        let frameA: SourceFrame = window[part.first]
        let frameB: SourceFrame = window[part.second]
        guard let textureA = try sourceTexture(frameA), let textureB = try sourceTexture(frameB) else {
            throw EngineError.exportFailed("素材の絵を読めません")
        }
        keep.append(textureA)
        keep.append(textureB)
        guard let a = CVMetalTextureGetTexture(textureA), let b = CVMetalTextureGetTexture(textureB) else {
            throw EngineError.exportFailed("素材の絵を読めません")
        }
        var from: Float = Float(part.from)
        var to: Float = Float(part.to)
        var mode: Int32 = 0
        var samples: Int32 = 1
        var forward: MTLTexture? = nil
        var backward: MTLTexture? = nil
        var scale: SIMD2<Float> = SIMD2<Float>(0, 0)
        if part.first != part.second {
            let state: PairState = try pairState(part.first)
            if state.cut {
                // カットをまたぐときは近いほうのコマをそのまま使う
                let nearest: Float = (from + to) / 2 < 0.5 ? 0 : 1
                from = nearest
                to = nearest
            } else if state.still {
                from = 0
                to = 0
            } else if let f = state.forward, let back = state.backward {
                mode = 1
                forward = f
                backward = back
                scale = state.scale
                // 動きの大きさに合わせて、シャッターの間を 1.5 画素ごとくらいに分ける
                let spread: Float = state.motion.isFinite ? state.motion * (to - from) : 0
                let steps: Float = min(48, max(1, (spread / 1.5).rounded(.up)))
                samples = Int32(steps)
            }
        }
        guard let encoder = commands.makeComputeCommandEncoder() else { throw EngineError.exportFailed("描画できません") }
        let filler: MTLTexture = try dummyTexture()
        var params = Params(t0: from, t1: to, weight: Float(part.weight), sigma: sigma, flowScale: scale,
                            samples: samples, mode: mode, accumulate: previous == nil ? 0 : 1, pad: 0)
        encoder.setComputePipelineState(owner.pipeline)
        encoder.setTexture(a, index: 0)
        encoder.setTexture(b, index: 1)
        encoder.setTexture(forward ?? filler, index: 2)
        encoder.setTexture(backward ?? filler, index: 3)
        encoder.setTexture(previous ?? filler, index: 4)
        encoder.setTexture(destination, index: 5)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: (destination.width + 15) / 16, height: (destination.height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    // MARK: 2 コマの関係

    private func pairState(_ index: Int) throws -> PairState {
        let key: Int = baseIndex + index
        if let known = pairs[key] { return known }
        let state = PairState()
        pairs[key] = state
        let a: SourceFrame = window[index]
        let b: SourceFrame = window[index + 1]
        guard let smallA = small(a), let smallB = small(b) else { return state }
        if a.signature == nil { a.signature = FrameInterpolator.cutSignature(smallA) }
        if b.signature == nil { b.signature = FrameInterpolator.cutSignature(smallB) }
        if let sa = a.signature, let sb = b.signature {
            state.cut = detector.isCut(sa, sb)
            state.still = !state.cut && SceneCutDetector.isStill(sa, sb)
        }
        if state.cut || state.still || plan.interpolation != .opticalFlow { return state }
        guard let forward = try? flowField(from: smallA, to: smallB), let backward = try? flowField(from: smallB, to: smallA) else {
            // 動きを読めなければ、このコマの間は重ねて作る
            return state
        }
        if method == .builtin {
            // 自前の推定は「A の各点が B で動いた先（画素）」と決まっている
            convention = FrameInterpolator.FlowConvention(sign: 1, normalized: false)
        } else if convention == nil {
            convention = FrameInterpolator.learnedConvention.get() ?? FrameInterpolator.calibrate(a: smallA, b: smallB, flow: forward)
            if let found = convention { FrameInterpolator.learnedConvention.set(found) }
        }
        let used: FrameInterpolator.FlowConvention = convention ?? FrameInterpolator.FlowConvention(sign: 1, normalized: false)
        state.forward = flowTexture(forward)
        state.backward = flowTexture(backward)
        let flowWidth: Float = Float(forward.width)
        let flowHeight: Float = Float(forward.height)
        state.scale = used.normalized ? SIMD2<Float>(used.sign, used.sign) : SIMD2<Float>(used.sign / flowWidth, used.sign / flowHeight)
        state.motion = FrameInterpolator.motionMagnitude(forward, convention: used, width: width, height: height)
        return state
    }

    private func flowField(from a: CVPixelBuffer, to b: CVPixelBuffer) throws -> FlowField {
        let all: [FrameInterpolator.FlowMethod] = [.vision(revision: nil), .vision(revision: VNGenerateOpticalFlowRequestRevision1), .builtin]
        // うまくいった求め方を先に。だめならほかも試す
        var order: [FrameInterpolator.FlowMethod] = all
        if let known = method {
            order = [known]
            for candidate in all where candidate != known {
                order.append(candidate)
            }
        }
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

    // MARK: 絵の用意

    /// 動きを求める用の小さい絵（長い辺を flowSide まで）。
    private func small(_ frame: SourceFrame) -> CVPixelBuffer? {
        if let made = frame.small { return made }
        let buffer: CVPixelBuffer = frame.buffer
        let w: Int = CVPixelBufferGetWidth(buffer)
        let h: Int = CVPixelBufferGetHeight(buffer)
        let ratio: Double = min(1, Double(FrameInterpolator.flowSide) / Double(max(w, h)))
        if ratio >= 0.999 {
            frame.small = buffer
            return buffer
        }
        let sw: Int = max(2, Int(Double(w) * ratio) / 2 * 2)
        let sh: Int = max(2, Int(Double(h) * ratio) / 2 * 2)
        if smallPool == nil || smallSize != (sw, sh) {
            let attributes: [String: Any] = FrameInterpolator.pixelAttributes(width: sw, height: sh)
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            smallPool = pool
            smallSize = (sw, sh)
        }
        guard let pool = smallPool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        guard let result = made else { return nil }
        let scale = CGAffineTransform(scaleX: CGFloat(sw) / CGFloat(w), y: CGFloat(sh) / CGFloat(h))
        let image: CIImage = CIImage(cvPixelBuffer: buffer).transformed(by: scale)
        owner.context.render(image, to: result, bounds: CGRect(x: 0, y: 0, width: sw, height: sh), colorSpace: nil)
        frame.small = result
        return result
    }

    private func sourceTexture(_ frame: SourceFrame) throws -> CVMetalTexture? {
        if let known = frame.texture { return known }
        let made: CVMetalTexture? = metalTexture(frame.buffer, write: false)
        frame.texture = made
        return made
    }

    private func accumulationTexture(_ index: Int) throws -> MTLTexture {
        while accumulation.count <= index {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            guard let texture = owner.device.makeTexture(descriptor: d) else { throw EngineError.exportFailed("作業用の絵を確保できません") }
            accumulation.append(texture)
        }
        return accumulation[index]
    }

    private func dummyTexture() throws -> MTLTexture {
        if let known = dummy { return known }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        guard let texture = owner.device.makeTexture(descriptor: d) else { throw EngineError.exportFailed("作業用の絵を確保できません") }
        dummy = texture
        return texture
    }

    private func flowTexture(_ field: FlowField) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg32Float, width: field.width, height: field.height, mipmapped: false)
        d.usage = .shaderRead
        guard let texture = owner.device.makeTexture(descriptor: d) else { return nil }
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

/// BGRA の絵の明るさを読む（calibrate・カットの判定用。最も近い画素）。
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
