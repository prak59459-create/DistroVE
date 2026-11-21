#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import XCTest
@testable import DistroKit

/// AVFoundation と Core Image を実際に動かすテスト（macOS で実行）。iPad と同じエンジンのコードを通す。
final class EngineTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distrove-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
    }

    override func tearDown() {
        AppPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// 色が時間で変わるテスト用の動画を作る。
    func makeVideo(seconds: Double, width: Int = 320, height: Int = 240, fps: Int = 30) async throws -> URL {
        let url: URL = root.appendingPathComponent("source-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames: Int = Int(seconds * Double(fps))
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixels: CVPixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<height {
                for x in 0..<width {
                    let p: Int = y * bytesPerRow + x * 4
                    base[p] = UInt8((i * 6) % 255)
                    base[p + 1] = UInt8((x + y) % 255)
                    base[p + 2] = UInt8(255 - (i * 6) % 255)
                    base[p + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    func makeProject() async throws -> Project {
        let videoURL: URL = try await makeVideo(seconds: 2)
        let asset: MediaAsset = try await MediaStore.shared.importFile(at: videoURL, copy: true)
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.width, 320)
        XCTAssertEqual(asset.duration.seconds, 2, accuracy: 0.05)
        var project = Project(name: "engine", canvas: CanvasSettings(aspect: .landscape16x9, shortSide: 360, fps: 30))
        project.media.append(asset)
        var first: Clip = project.makeClip(for: asset)
        first.effects.append(VideoEffect(kind: .glitch))
        first.look = LookSettings(id: "builtin:film")
        first.color.set(ColorSpecs.saturation, Param(1.3))
        project.appendToMain(first)
        var second: Clip = project.makeClip(for: asset)
        second.transitionIn = ClipTransition(kind: .cube3D, duration: Time(seconds: 0.5))
        second.transform.rotationY = Param(20)
        project.appendToMain(second)
        var text = Clip(kind: .text, name: "title", start: Time(seconds: 0.5), duration: Time(seconds: 2))
        var content: TextContent = TextPresets.outline().content
        content.string = "こんにちは Distro VE"
        content.animation = .typewriter
        text.text = content
        project.placeOverlay(text, at: text.start)
        var shape = Clip(kind: .shape, name: "arrow", start: .zero, duration: Time(seconds: 1))
        shape.shape = ShapeContent(kind: .arrow)
        shape.animationIn = ClipAnimation(kind: .pop)
        project.placeOverlay(shape, at: .zero)
        var mosaic = Clip(kind: .adjustment, name: "mosaic", start: Time(seconds: 1), duration: Time(seconds: 1))
        mosaic.effects.append(VideoEffect(kind: .mosaic))
        var mask = MaskSettings(shape: .rectangle)
        mask.width = Param(0.3)
        mask.height = Param(0.3)
        mosaic.mask = mask
        project.placeOverlay(mosaic, at: mosaic.start)
        let bgm: MediaAsset = try await SoundLibraryStore.importSound("bgm.drums")
        project.media.append(bgm)
        var music: Clip = project.makeClip(for: bgm)
        music.duration = Time(seconds: 4)
        music.audio.fadeOut = Time(seconds: 1)
        project.placeAudio(music, at: .zero)
        project.setCues([SubtitleCue(start: .zero, end: Time(seconds: 2), text: "字幕のテスト")], replace: true)
        project.setBeatMarkers([Time(seconds: 0.6), Time(seconds: 1.2), Time(seconds: 1.8)])
        return project
    }

    func testExportMP4() async throws {
        let project: Project = try await makeProject()
        XCTAssertEqual(project.duration, Time(seconds: 4))
        var settings = ExportSettings()
        settings.resolution = .p480
        settings.fps = 30
        let output: URL = root.appendingPathComponent("out.mp4")
        let started = Date()
        try await Exporter().export(project: project, settings: settings, to: output, progress: { _ in })
        print("書き出し時間: \(Date().timeIntervalSince(started)) 秒 / GPU: \(FrameRenderer.shared.usesGPU)")
        let result = AVURLAsset(url: output)
        let duration: CMTime = try await result.load(.duration)
        XCTAssertEqual(duration.seconds, 4, accuracy: 0.15)
        let videoTracks: [AVAssetTrack] = try await result.loadTracks(withMediaType: .video)
        let audioTracks: [AVAssetTrack] = try await result.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let size: CGSize = try await videoTracks[0].load(.naturalSize)
        let expected: (width: Int, height: Int) = settings.outputSize(canvasWidth: project.canvas.width, canvasHeight: project.canvas.height)
        XCTAssertEqual(Int(size.height), expected.height)
        XCTAssertEqual(Int(size.width), expected.width)
        // 真っ黒ではないこと
        let generator = AVAssetImageGenerator(asset: result)
        let frame: CGImage = try await generator.image(at: CMTime(seconds: 1.0, preferredTimescale: 600)).image
        XCTAssertGreaterThan(averageBrightness(frame), 0.05)
    }

    func testExportGIFAndStill() async throws {
        var project: Project = try await makeProject()
        AutoEdit.trimTimeline(project: &project, to: Time(seconds: 1))
        var settings = ExportSettings()
        settings.format = .gif
        settings.gifFps = 10
        settings.gifMaxWidth = 160
        let output: URL = root.appendingPathComponent("out.gif")
        try await Exporter().export(project: project, settings: settings, to: output, progress: { _ in })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 10)
        let still: CGImage = try await Exporter().still(project: project, at: Time(seconds: 0.5), maxSide: 320)
        XCTAssertEqual(still.width, 320)
    }

    func testAudioAnalysisFindsBeats() async throws {
        let bgm: MediaAsset = try await SoundLibraryStore.importSound("bgm.phonk")
        let url: URL = try XCTUnwrap(MediaStore.shared.url(for: bgm))
        let features: AudioFeatures = try await AudioAnalyzer.features(for: bgm, url: url)
        XCTAssertGreaterThan(features.frameCount, 2000)
        let beats = try XCTUnwrap(BeatDetector.analyze(features))
        let ratio: Double = beats.bpm / 130
        XCTAssertTrue(abs(ratio - 1) < 0.05 || abs(ratio - 0.5) < 0.03 || abs(ratio - 2) < 0.1, "bpm \(beats.bpm)")
        XCTAssertNotNil(Loudness.integratedLUFS(features))
        XCTAssertNotNil(AudioAnalyzer.cached(bgm))
    }

    func testTemperatureMakesWarmer() {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var clip = Clip(kind: .image, name: "g", start: .zero, duration: Time(seconds: 1))
        clip.color.set(ColorSpecs.temperature, Param(0.8))
        let warm: CIImage = ColorPipeline().apply(clip: clip, to: gray, at: .zero)
        let pixel: [Float] = readPixel(warm)
        XCTAssertGreaterThan(pixel[0], pixel[2], "暖かくすると赤が青より強くなる")
    }

    func testTextAndShapeRasterize() throws {
        let text = TextContent(string: "日本語のテキスト\n2 行目")
        let image = try XCTUnwrap(TextRasterizer().image(text, fontPixels: 48, maxWidth: 400))
        XCTAssertGreaterThan(image.extent.width, 100)
        XCTAssertGreaterThan(image.extent.height, 90)
        let partial = try XCTUnwrap(TextRasterizer().image(text, fontPixels: 48, maxWidth: 400, visibleCharacters: 3))
        XCTAssertEqual(partial.extent.size, image.extent.size)
        let shape = try XCTUnwrap(ShapeRasterizer().image(ShapeContent(kind: .star), boxHeight: 100))
        XCTAssertGreaterThan(shape.extent.width, 90)
    }

    func testReverseAndProxy() async throws {
        let url: URL = try await makeVideo(seconds: 1, width: 640, height: 360)
        let asset: MediaAsset = try await MediaStore.shared.importFile(at: url, copy: true)
        let reversedPath: String = try await MediaJobs.makeReversed(for: asset)
        let reversed = AVURLAsset(url: AppPaths.media.appendingPathComponent(reversedPath))
        let duration: CMTime = try await reversed.load(.duration)
        XCTAssertEqual(duration.seconds, 1, accuracy: 0.1)
        let proxyPath: String = try await MediaJobs.makeProxy(for: asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppPaths.media.appendingPathComponent(proxyPath).path))
    }

    func testProjectStoreRoundTrip() throws {
        let store = ProjectStore()
        var project = Project(name: "保存テスト", canvas: CanvasSettings(aspect: .portrait9x16))
        try store.save(project)
        XCTAssertEqual(store.list().first?.name, "保存テスト")
        project.name = "変更後"
        store.backup(project)
        XCTAssertEqual(store.backups(project.id).count, 1)
        let copy: Project = try store.duplicate(project.id)
        XCTAssertNotEqual(copy.id, project.id)
        store.markEditing(project.id)
        XCTAssertEqual(store.interruptedProject(), project.id)
        store.markClosed()
        XCTAssertNil(store.interruptedProject())
        store.delete(project.id)
        XCTAssertEqual(store.list().count, 1)
    }

    func testAudioProcessing() async throws {
        let sound: MediaAsset = try await SoundLibraryStore.importSound("sfx.ding")
        let url: URL = try XCTUnwrap(MediaStore.shared.url(for: sound))
        var processing = AudioProcessing()
        processing.voice = .chipmunk
        processing.eq = .voice
        processing.denoise = 0.5
        let path: String = try await AudioProcessor.render(source: url, processing: processing)
        let rendered = AVURLAsset(url: AppPaths.media.appendingPathComponent(path))
        let duration: CMTime = try await rendered.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 0.8)
    }

    // MARK: 補助

    func averageBrightness(_ image: CGImage) -> Double {
        let w: Int = 32
        let h: Int = 18
        let pixels: [UInt8] = VisionTools.grayscale(image, width: w, height: h)
        var total: Int = 0
        for p in pixels { total += Int(p) }
        return Double(total) / Double(pixels.count) / 255
    }

    func readPixel(_ image: CIImage) -> [Float] {
        var bitmap: [Float] = [0, 0, 0, 0]
        let context = CIContext()
        context.render(image, toBitmap: &bitmap, rowBytes: 16, bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bitmap
    }
}
#endif
