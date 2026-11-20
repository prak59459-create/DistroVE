#if canImport(Vision) && canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import DistroKit

/// 速さを変えたクリップのコマ作り（Q99: 光学フロー・コマの合成・モーションブラー・カット）を実際に動かすテスト（macOS で実行）。
final class InterpolationTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distrove-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
    }

    override func tearDown() {
        AppPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let width: Int = 320
    private let height: Int = 240
    private let squareSize: Int = 48

    /// 市松模様の四角が 1 コマに 8 画素ずつ右へ動く動画。cutAt を渡すと、そのコマからは横じまの別の場面になる。
    private func makeMovingSquare(frames: Int, fps: Int, cutAt: Int? = nil, step: Int = 8) async throws -> URL {
        let url: URL = root.appendingPathComponent("square-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [:]
        settings[AVVideoCodecKey] = AVVideoCodecType.h264
        settings[AVVideoWidthKey] = width
        settings[AVVideoHeightKey] = height
        var quality: [String: Any] = [:]
        quality[AVVideoAverageBitRateKey] = 8_000_000
        settings[AVVideoCompressionPropertiesKey] = quality
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &made)
            let buffer: CVPixelBuffer = try XCTUnwrap(made)
            if let cut = cutAt, i >= cut {
                drawStripes(buffer, offset: i - cut)
            } else {
                draw(buffer, left: 20 + i * step, top: 96)
            }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func draw(_ buffer: CVPixelBuffer, left: Int, top: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base: UnsafeMutablePointer<UInt8> = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let inside: Bool = x >= left && x < left + squareSize && y >= top && y < top + squareSize
                let checker: Bool = ((x - left) / 8 + (y - top) / 8) % 2 == 0
                let value: UInt8 = inside ? (checker ? 255 : 200) : 30
                let p: Int = y * bytesPerRow + x * 4
                base[p] = value
                base[p + 1] = value
                base[p + 2] = value
                base[p + 3] = 255
            }
        }
    }

    /// カットの後の場面（横じま。少しずつ下へ動く）。
    private func drawStripes(_ buffer: CVPixelBuffer, offset: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base: UnsafeMutablePointer<UInt8> = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let band: Bool = ((y + offset * 2) / 20) % 2 == 0
            for x in 0..<width {
                let value: UInt8 = band ? UInt8(90 + x % 40) : 160
                let p: Int = y * bytesPerRow + x * 4
                base[p] = value
                base[p + 1] = value
                base[p + 2] = value
                base[p + 3] = 255
            }
        }
    }

    /// 1 コマの調べた結果。
    private struct FrameInfo {
        var time: Double
        /// 明るい画素の重心の x（無ければ -1）と数
        var centroid: Double
        var bright: Int
        /// 中間の明るさ（二重に重なった所）の画素の数
        var halfTone: Int
        /// 真ん中の行で、背景より明るい画素の幅
        var rowWidth: Int
        /// 縮小した明るさ（コマどうしの比較用）
        var thumbnail: [Double]
    }

    private func inspect(_ buffer: CVPixelBuffer, time: Double) -> FrameInfo {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base: UnsafeMutablePointer<UInt8> = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(buffer)
        let w: Int = CVPixelBufferGetWidth(buffer)
        let h: Int = CVPixelBufferGetHeight(buffer)
        var sum: Double = 0
        var bright: Int = 0
        var half: Int = 0
        var rowWidth: Int = 0
        var thumbnail: [Double] = Array(repeating: 0, count: 16 * 12)
        for y in 0..<h {
            for x in 0..<w {
                let value: UInt8 = base[y * bytesPerRow + x * 4 + 1]
                if value > 150 {
                    sum += Double(x)
                    bright += 1
                } else if value > 110 && value < 150 {
                    half += 1
                }
                if y == h / 2 && value > 60 { rowWidth += 1 }
                let cell: Int = min(11, y * 12 / h) * 16 + min(15, x * 16 / w)
                thumbnail[cell] += Double(value)
            }
        }
        let perCell: Double = Double(w * h) / Double(16 * 12)
        for i in 0..<thumbnail.count { thumbnail[i] /= perCell }
        return FrameInfo(time: time, centroid: bright > 0 ? sum / Double(bright) : -1, bright: bright, halfTone: half,
                         rowWidth: rowWidth, thumbnail: thumbnail)
    }

    private func read(_ url: URL) async throws -> [FrameInfo] {
        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        let track: AVAssetTrack = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: asset)
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: attributes)
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var frames: [FrameInfo] = []
        while let sample = out.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(inspect(buffer, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        return frames
    }

    private func sourceAsset(_ url: URL, seconds: Double) -> MediaAsset {
        var asset = MediaAsset(kind: .video, name: "square", storage: .copied)
        asset.duration = Time(seconds: seconds)
        asset.frameRate = 30
        asset.width = width
        asset.height = height
        return asset
    }

    private func slowClip(rate: Double, duration: Double, mode: FrameInterpolation, blur: Double = 0) -> Clip {
        var clip = Clip(kind: .video, name: "square", start: .zero, duration: Time(seconds: duration))
        clip.speed = SpeedSettings(rate: rate)
        clip.speed.interpolation = mode
        clip.speed.motionBlur = blur
        return clip
    }

    private func render(_ clip: Clip, source: URL, seconds: Double) async throws -> (RetimePlan, [FrameInfo]) {
        let interpolator: FrameInterpolator = try XCTUnwrap(FrameInterpolator.shared)
        let plan = RetimePlan(clip: clip, asset: sourceAsset(source, seconds: seconds), fps: 30)
        let output: URL = root.appendingPathComponent("retimed-\(UUID().uuidString).mov")
        try await interpolator.render(plan: plan, url: source, accuracy: .high, output: output, progress: nil)
        return (plan, try await read(output))
    }

    func testOpticalFlowHalfSpeedPutsTheSquareHalfwayWithoutGhosts() async throws {
        let source: URL = try await makeMovingSquare(frames: 30, fps: 30)
        let (plan, frames) = try await render(slowClip(rate: 0.5, duration: 1.8, mode: .opticalFlow), source: source, seconds: 1)
        XCTAssertEqual(plan.frames.count, 54)
        XCTAssertEqual(frames.count, 54)
        // 最初のコマは 0 秒、あとはタイムラインのコマの半コマ前（合成が隣のコマを拾わないように）
        XCTAssertEqual(frames[0].time, 0, accuracy: 0.001)
        XCTAssertEqual(frames[1].time, 1.0 / 30 - 1.0 / 60, accuracy: 0.001)
        XCTAssertEqual(frames[2].time - frames[1].time, 1.0 / 30, accuracy: 0.001)
        for k in 5..<25 {
            let before: FrameInfo = frames[2 * k]
            let middle: FrameInfo = frames[2 * k + 1]
            let after: FrameInfo = frames[2 * k + 2]
            XCTAssertEqual(middle.centroid, (before.centroid + after.centroid) / 2, accuracy: 2.5, "コマ \(2 * k + 1)")
            // 二重にぼやけていない（明るい画素が元のコマと同じくらいあり、中間の明るさが元のコマより大きく増えない）
            XCTAssertGreaterThan(Double(middle.bright), Double(before.bright) * 0.7, "コマ \(2 * k + 1)")
            XCTAssertLessThan(middle.halfTone, before.halfTone + 250, "コマ \(2 * k + 1)")
        }
    }

    func testBlendingMakesTheInBetweenFromBothFrames() async throws {
        let source: URL = try await makeMovingSquare(frames: 30, fps: 30)
        let (_, frames) = try await render(slowClip(rate: 0.5, duration: 1.8, mode: .blending), source: source, seconds: 1)
        XCTAssertEqual(frames.count, 54)
        for k in 5..<25 {
            let before: FrameInfo = frames[2 * k]
            let middle: FrameInfo = frames[2 * k + 1]
            let after: FrameInfo = frames[2 * k + 2]
            XCTAssertEqual(middle.centroid, (before.centroid + after.centroid) / 2, accuracy: 2.5, "コマ \(2 * k + 1)")
            // 重ねたので、はみ出た所（左右 8 画素ずつ）が中間の明るさになる
            XCTAssertGreaterThan(middle.halfTone, before.halfTone + 400, "コマ \(2 * k + 1)")
        }
    }

    func testCutIsNotInterpolated() async throws {
        let source: URL = try await makeMovingSquare(frames: 30, fps: 30, cutAt: 15)
        let (plan, frames) = try await render(slowClip(rate: 0.5, duration: 1.8, mode: .opticalFlow), source: source, seconds: 1)
        XCTAssertEqual(frames.count, plan.frames.count)
        // 出力の 29 コマ目は素材の 14 コマ目と 15 コマ目（カット）の真ん中。どちらかのコマそのものになる
        let before: FrameInfo = frames[28]
        let middle: FrameInfo = frames[29]
        let after: FrameInfo = frames[30]
        let toBefore: Double = distance(middle.thumbnail, before.thumbnail)
        let toAfter: Double = distance(middle.thumbnail, after.thumbnail)
        XCTAssertLessThan(min(toBefore, toAfter), 2, "前 \(toBefore) / 後 \(toAfter)")
        XCTAssertGreaterThan(distance(before.thumbnail, after.thumbnail), 20)
        // カットのない所は間を作っている
        XCTAssertEqual(frames[21].centroid, (frames[20].centroid + frames[22].centroid) / 2, accuracy: 2.5)
    }

    func testMotionBlurStretchesAlongTheMotion() async throws {
        let source: URL = try await makeMovingSquare(frames: 30, fps: 30)
        let (_, sharp) = try await render(slowClip(rate: 1, duration: 0.8, mode: .opticalFlow), source: source, seconds: 1)
        let (_, blurred) = try await render(slowClip(rate: 1, duration: 0.8, mode: .opticalFlow, blur: 1), source: source, seconds: 1)
        XCTAssertEqual(blurred.count, sharp.count)
        for k in 5..<20 {
            // 360° のシャッターなら、1 コマに動く 8 画素ぶん横に伸び、位置（重心）は変わらない
            XCTAssertGreaterThanOrEqual(blurred[k].rowWidth, sharp[k].rowWidth + 4, "コマ \(k)")
            XCTAssertEqual(blurred[k].centroid, sharp[k].centroid, accuracy: 3, "コマ \(k)")
        }
    }

    func testCompositionPlaysTheRetimedFrames() async throws {
        let source: URL = try await makeMovingSquare(frames: 30, fps: 30)
        let asset: MediaAsset = try await MediaStore.shared.importFile(at: source, copy: true)
        var project = Project(name: "retime", canvas: CanvasSettings(aspect: .landscape4x3, shortSide: 240, fps: 30))
        project.media.append(asset)
        var clip: Clip = project.makeClip(for: asset)
        clip.speed = SpeedSettings(rate: 0.5)
        clip.duration = Time(seconds: 1.8)
        clip.speed.interpolation = .opticalFlow
        project.appendToMain(clip)
        let placed: Clip = try XCTUnwrap(project.tracks[try XCTUnwrap(project.mainTrackIndex)].clips.first)
        XCTAssertTrue(MediaJobs.needsRetime(placed, asset: asset, fps: 30))
        let path: String = try await MediaJobs.makeRetimed(clip: placed, asset: asset, fps: 30)
        XCTAssertEqual(path, RetimePlan.cachePath(clip: placed, asset: asset, fps: 30))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.media.appendingPathComponent(path).path))
        // もう一度頼んでも作り直さない（同じファイル）
        let again: String = try await MediaJobs.makeRetimed(clip: placed, asset: asset, fps: 30)
        XCTAssertEqual(again, path)

        var options = CompositionBuilder.Options()
        options.includeAudio = false
        let built: CompositionBuilder.Result = try await CompositionBuilder().build(project: project, options: options)
        let reader = try AVAssetReader(asset: built.composition)
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: attributes)
        output.videoComposition = built.videoComposition
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [FrameInfo] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(inspect(buffer, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        XCTAssertGreaterThanOrEqual(frames.count, 50)
        // 合成の出力でも、間のコマが前後のちょうど真ん中にある（作ったコマを 1 コマずつ使っている）
        for k in 5..<24 {
            let middle: FrameInfo = frames[2 * k + 1]
            let expected: Double = (frames[2 * k].centroid + frames[2 * k + 2].centroid) / 2
            XCTAssertEqual(middle.centroid, expected, accuracy: 2.5, "コマ \(2 * k + 1)")
            XCTAssertGreaterThan(frames[2 * k + 2].centroid - frames[2 * k].centroid, 5, "コマ \(2 * k)")
        }
    }

    /// スムースカット：切れ目をはさむ区間は、光学フローで変形させたコマになる（二重に重ならず、区間の端で絵が飛ばない）。
    func testSmoothCutMorphsAcrossAJumpCut() async throws {
        let source: URL = try await makeMovingSquare(frames: 30, fps: 30, step: 3)
        let asset: MediaAsset = try await MediaStore.shared.importFile(at: source, copy: true)
        var project = Project(name: "smooth", canvas: CanvasSettings(aspect: .landscape4x3, shortSide: 240, fps: 30))
        project.media.append(asset)
        // A は素材の 0〜0.5 秒、B は 0.7 秒から（0.2 秒ぶんを切ったジャンプカット）
        var a: Clip = project.makeClip(for: asset)
        a.sourceStart = .zero
        a.duration = Time(seconds: 0.5)
        project.appendToMain(a)
        var b: Clip = project.makeClip(for: asset)
        b.sourceStart = Time(seconds: 0.7)
        b.duration = Time(seconds: 0.3)
        b.transitionIn = ClipTransition(kind: .smoothCut, duration: Time(seconds: 0.2))
        project.appendToMain(b)
        let items = SmoothCutPlan.all(in: project, fps: 30)
        XCTAssertEqual(items.count, 1)
        let plan: SmoothCutPlan = try XCTUnwrap(items.first?.plan)
        let path: String = try await MediaJobs.makeSmoothCut(plan, assetA: asset, assetB: asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.media.appendingPathComponent(path).path))

        var options = CompositionBuilder.Options()
        options.includeAudio = false
        let built: CompositionBuilder.Result = try await CompositionBuilder().build(project: project, options: options)
        let reader = try AVAssetReader(asset: built.composition)
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: built.composition.tracks(withMediaType: .video), videoSettings: attributes)
        output.videoComposition = built.videoComposition
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [FrameInfo] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(inspect(buffer, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        XCTAssertGreaterThanOrEqual(frames.count, 24)
        // 区間は 0.4〜0.6 秒（コマ 12〜17）。区間の前後のコマの位置
        let before: FrameInfo = frames[11]
        let after: FrameInfo = frames[18]
        var previous: Double = before.centroid
        for k in 12...17 {
            let frame: FrameInfo = frames[k]
            // 前のコマから少しずつ進み、行き過ぎない（絵が飛ばない）
            XCTAssertGreaterThan(frame.centroid, previous - 1.5, "コマ \(k)")
            XCTAssertLessThan(frame.centroid - previous, 14, "コマ \(k)")
            XCTAssertLessThan(frame.centroid, after.centroid + 1.5, "コマ \(k)")
            // 二重にならない（クロスフェードなら中間の明るさが大きく増える）
            XCTAssertLessThan(frame.halfTone, before.halfTone + 250, "コマ \(k)")
            XCTAssertGreaterThan(Double(frame.bright), Double(before.bright) * 0.7, "コマ \(k)")
            previous = frame.centroid
        }
        XCTAssertLessThan(after.centroid - previous, 14)
        XCTAssertGreaterThan(after.centroid - before.centroid, 20)
    }

    private func distance(_ a: [Double], _ b: [Double]) -> Double {
        var sum: Double = 0
        for i in 0..<min(a.count, b.count) { sum += abs(a[i] - b[i]) }
        return sum / Double(max(1, min(a.count, b.count)))
    }
}
#endif
