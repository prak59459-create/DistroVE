#if canImport(AVFoundation)
import AVFoundation
import Foundation
import ImageIO

/// 書き出し（Q72〜Q74, Q83）。AVAssetReader で合成した映像を読み、AVAssetWriter のハードウェアエンコーダーで MP4 にする。
final class Exporter: @unchecked Sendable {
    private let cancelled = Locked<Bool>(false)
    private let builder: CompositionBuilder

    init(builder: CompositionBuilder = CompositionBuilder()) {
        self.builder = builder
    }

    func cancel() {
        cancelled.set(true)
    }

    var isCancelled: Bool { return cancelled.get() }

    func export(project: Project, settings: ExportSettings, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        cancelled.set(false)
        if settings.format == .gif {
            try await exportGIF(project: project, settings: settings, to: url, progress: progress)
        } else {
            try await exportVideo(project: project, settings: settings, to: url, progress: progress)
        }
    }

    // MARK: MP4

    func exportVideo(project: Project, settings: ExportSettings, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        // 速さを変えたクリップのコマを、書き出すフレームレートで先に作る（Q99）
        let share: Double = try await prepareRetimed(project: project, fps: Double(settings.fps), progress: progress)
        let rest: Double = 1 - share
        let report: @Sendable (Double) -> Void = { value in progress(share + rest * value) }
        let size: (width: Int, height: Int) = settings.outputSize(canvasWidth: project.canvas.width, canvasHeight: project.canvas.height)
        var options = CompositionBuilder.Options()
        options.renderSize = CGSize(width: size.width, height: size.height)
        options.fps = Double(settings.fps)
        options.includeAudio = settings.includeAudio
        let built: CompositionBuilder.Result = try await builder.build(project: project, options: options)
        let whole = TimeRange(start: .zero, duration: built.duration)
        let range: CMTimeRange = (settings.range ?? whole).cmTimeRange
        let source: ReaderSetup = try Exporter.makeReader(built: built, range: range, includeAudio: settings.includeAudio)
        try? FileManager.default.removeItem(at: url)
        let sink: WriterSetup = try Exporter.makeWriter(url: url, settings: settings, width: size.width, height: size.height, withAudio: source.audio != nil)
        guard source.reader.startReading() else {
            throw EngineError.exportFailed(source.reader.error?.localizedDescription ?? "読み込みを始められません")
        }
        guard sink.writer.startWriting() else {
            throw EngineError.exportFailed(sink.writer.error?.localizedDescription ?? "書き込みを始められません")
        }
        sink.writer.startSession(atSourceTime: range.start)
        let job = TranscodeJob(source: source, sink: sink, url: url, range: range, cancelFlag: cancelled, progress: report)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            job.run(continuation)
        }
    }

    /// 速さを変えたクリップ（光学フロー・コマの合成・モーションブラー）のコマを、書き出すフレームレートで作っておく。
    /// 進み具合のうち、ここで使った割合を返す。作れなかったクリップはコマの繰り返しで書き出す。
    private func prepareRetimed(project: Project, fps: Double, progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        var work: [(clip: Clip, asset: MediaAsset, frames: Int)] = []
        var total: Int = 0
        for index in project.trackIndices(of: .video) where !project.tracks[index].isHidden {
            for clip in project.tracks[index].clips where clip.kind == .video && clip.speed.makesFrames {
                guard let asset = project.asset(clip.mediaID) else { continue }
                let plan = RetimePlan(clip: clip, asset: asset, fps: fps)
                if !plan.isNeeded(sourceFPS: asset.frameRate) { continue }
                if FileManager.default.fileExists(atPath: AppPaths.media.appendingPathComponent(plan.cachePath).path) { continue }
                work.append((clip, asset, plan.frames.count))
                total += plan.frames.count
            }
        }
        // スムースカットのコマ（1 つを 30 コマぶんの手間とみなす）
        var morphs: [(plan: SmoothCutPlan, a: MediaAsset, b: MediaAsset)] = []
        for item in SmoothCutPlan.all(in: project, fps: fps) {
            if FileManager.default.fileExists(atPath: AppPaths.media.appendingPathComponent(item.plan.cachePath).path) { continue }
            guard let a = project.asset(item.from.mediaID), let b = project.asset(item.to.mediaID) else { continue }
            morphs.append((item.plan, a, b))
            total += 30
        }
        if (work.isEmpty && morphs.isEmpty) || total == 0 { return 0 }
        let share: Double = 0.6
        var done: Int = 0
        let flag: Locked<Bool> = cancelled
        let all: Int = total
        for item in work {
            if isCancelled { throw EngineError.cancelled }
            let offset: Int = done
            let count: Int = item.frames
            let report: @Sendable (Double) -> Void = { value in
                progress(share * (Double(offset) + value * Double(count)) / Double(all))
            }
            do {
                _ = try await MediaJobs.makeRetimed(clip: item.clip, asset: item.asset, fps: fps, progress: report,
                                                    isCancelled: { flag.get() })
            } catch EngineError.cancelled {
                throw EngineError.cancelled
            } catch {
                Diagnostics.shared.log("retime before export failed: \(error)")
            }
            done += count
        }
        for item in morphs {
            if isCancelled { throw EngineError.cancelled }
            let offset: Int = done
            let report: @Sendable (Double) -> Void = { value in
                progress(share * (Double(offset) + value * 30) / Double(all))
            }
            do {
                _ = try await MediaJobs.makeSmoothCut(item.plan, assetA: item.a, assetB: item.b, progress: report, isCancelled: { flag.get() })
            } catch EngineError.cancelled {
                throw EngineError.cancelled
            } catch {
                Diagnostics.shared.log("smooth cut before export failed: \(error)")
            }
            done += 30
        }
        return share
    }

    /// 読み込み側。合成した映像（と音）を取り出す出口を用意する。
    private static func makeReader(built: CompositionBuilder.Result, range: CMTimeRange, includeAudio: Bool) throws -> ReaderSetup {
        let composition: AVComposition = built.composition
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = range
        let videoTracks: [AVAssetTrack] = composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: Exporter.readerVideoSettings())
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        if reader.canAdd(videoOutput) { reader.add(videoOutput) }
        let audioTracks: [AVAssetTrack] = composition.tracks(withMediaType: .audio)
        guard includeAudio && !audioTracks.isEmpty else {
            return ReaderSetup(reader: reader, video: videoOutput, audio: nil)
        }
        let audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: Exporter.readerAudioSettings())
        audioOutput.audioMix = built.audioMix
        audioOutput.audioTimePitchAlgorithm = .spectral
        audioOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(audioOutput) else {
            return ReaderSetup(reader: reader, video: videoOutput, audio: nil)
        }
        reader.add(audioOutput)
        return ReaderSetup(reader: reader, video: videoOutput, audio: audioOutput)
    }

    /// 書き込み側。ハードウェアエンコーダーへの入口を用意する。
    private static func makeWriter(url: URL, settings: ExportSettings, width: Int, height: Int, withAudio: Bool) throws -> WriterSetup {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoSettings: [String: Any] = Exporter.writerVideoSettings(settings, width: width, height: height)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw EngineError.exportFailed("この設定では映像を書き出せません") }
        writer.add(videoInput)
        guard withAudio else {
            return WriterSetup(writer: writer, video: videoInput, audio: nil)
        }
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: Exporter.writerAudioSettings())
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(audioInput) else {
            return WriterSetup(writer: writer, video: videoInput, audio: nil)
        }
        writer.add(audioInput)
        return WriterSetup(writer: writer, video: videoInput, audio: audioInput)
    }

    // 設定の辞書は 1 項目ずつ入れる（値の型が混ざった辞書リテラルは型チェックが重い）

    private static func readerVideoSettings() -> [String: Any] {
        let format: OSType = kCVPixelFormatType_32BGRA
        var values: [String: Any] = [:]
        values[kCVPixelBufferPixelFormatTypeKey as String] = format
        return values
    }

    private static func readerAudioSettings() -> [String: Any] {
        var values: [String: Any] = [:]
        values[AVFormatIDKey] = kAudioFormatLinearPCM
        values[AVSampleRateKey] = 48_000
        values[AVNumberOfChannelsKey] = 2
        values[AVLinearPCMBitDepthKey] = 16
        values[AVLinearPCMIsFloatKey] = false
        values[AVLinearPCMIsBigEndianKey] = false
        values[AVLinearPCMIsNonInterleaved] = false
        return values
    }

    private static func writerVideoSettings(_ settings: ExportSettings, width: Int, height: Int) -> [String: Any] {
        var compression: [String: Any] = [:]
        compression[AVVideoAverageBitRateKey] = settings.effectiveBitrate(width: width, height: height)
        compression[AVVideoExpectedSourceFrameRateKey] = settings.fps
        compression[AVVideoMaxKeyFrameIntervalKey] = settings.fps * 2
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        var color: [String: Any] = [:]
        color[AVVideoColorPrimariesKey] = AVVideoColorPrimaries_ITU_R_709_2
        color[AVVideoTransferFunctionKey] = AVVideoTransferFunction_ITU_R_709_2
        color[AVVideoYCbCrMatrixKey] = AVVideoYCbCrMatrix_ITU_R_709_2
        let codec: AVVideoCodecType = settings.codec == .hevc ? .hevc : .h264
        var values: [String: Any] = [:]
        values[AVVideoCodecKey] = codec
        values[AVVideoWidthKey] = width
        values[AVVideoHeightKey] = height
        values[AVVideoCompressionPropertiesKey] = compression
        values[AVVideoColorPropertiesKey] = color
        return values
    }

    private static func writerAudioSettings() -> [String: Any] {
        var values: [String: Any] = [:]
        values[AVFormatIDKey] = kAudioFormatMPEG4AAC
        values[AVSampleRateKey] = 48_000
        values[AVNumberOfChannelsKey] = 2
        values[AVEncoderBitRateKey] = 192_000
        return values
    }

    // MARK: GIF

    func exportGIF(project: Project, settings: ExportSettings, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let size: (width: Int, height: Int) = settings.gifSize(canvasWidth: project.canvas.width, canvasHeight: project.canvas.height)
        var options = CompositionBuilder.Options()
        options.renderSize = CGSize(width: size.width, height: size.height)
        options.fps = Double(settings.gifFps)
        options.includeAudio = false
        let built: CompositionBuilder.Result = try await builder.build(project: project, options: options)
        let range: TimeRange = settings.range ?? TimeRange(start: .zero, duration: built.duration)
        let fps: Double = Double(max(1, settings.gifFps))
        let count: Int = max(1, min(900, Int(range.duration.seconds * fps)))
        try? FileManager.default.removeItem(at: url)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw EngineError.exportFailed("GIF を作れません")
        }
        let fileProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, fileProperties as CFDictionary)
        let frameProperties: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]]
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: size.width, height: size.height)
        for i in 0..<count {
            if cancelled.get() {
                try? FileManager.default.removeItem(at: url)
                throw EngineError.cancelled
            }
            let t: Time = range.start + Time(seconds: Double(i) / fps)
            let image: CGImage = try await generator.image(at: t.cmTime).image
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
            progress(Double(i + 1) / Double(count))
        }
        if !CGImageDestinationFinalize(destination) {
            throw EngineError.exportFailed("GIF を保存できません")
        }
    }

    // MARK: 1 枚の画像

    /// 指定時刻の完成画像（サムネイル・プロジェクト一覧用）。
    func still(project: Project, at time: Time, maxSide: CGFloat) async throws -> CGImage {
        var options = CompositionBuilder.Options()
        let scale: Double = Double(maxSide) / Double(max(project.canvas.width, project.canvas.height))
        options.renderScale = min(1, scale)
        options.includeAudio = false
        let built: CompositionBuilder.Result = try await builder.build(project: project, options: options)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let t: Time = min(time, max(.zero, built.duration - project.frameDuration))
        return try await generator.image(at: t.cmTime).image
    }
}

/// 読み込み側（合成した映像と音の出口）。
private struct ReaderSetup {
    let reader: AVAssetReader
    let video: AVAssetReaderVideoCompositionOutput
    let audio: AVAssetReaderAudioMixOutput?
}

/// 書き込み側（エンコーダーへの入口）。
private struct WriterSetup {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
}

/// 読んだサンプルを書き込み側へ流す。映像と音は別のキューで並行に進め、両方が終わったら仕上げる。
private final class TranscodeJob: @unchecked Sendable {
    private let source: ReaderSetup
    private let sink: WriterSetup
    private let url: URL
    private let startSeconds: Double
    private let totalSeconds: Double
    private let cancelFlag: Locked<Bool>
    private let progress: @Sendable (Double) -> Void
    private let group = DispatchGroup()

    init(source: ReaderSetup, sink: WriterSetup, url: URL, range: CMTimeRange, cancelFlag: Locked<Bool>, progress: @escaping @Sendable (Double) -> Void) {
        self.source = source
        self.sink = sink
        self.url = url
        self.startSeconds = range.start.seconds
        self.totalSeconds = max(0.001, range.duration.seconds)
        self.cancelFlag = cancelFlag
        self.progress = progress
    }

    func run(_ continuation: CheckedContinuation<Void, Error>) {
        group.enter()
        pump(from: source.video, to: sink.video, label: "com.distrove.export.video", reportsProgress: true)
        if let input = sink.audio, let output = source.audio {
            group.enter()
            pump(from: output, to: input, label: "com.distrove.export.audio", reportsProgress: false)
        }
        group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
            self.finish(continuation)
        }
    }

    private func pump(from output: AVAssetReaderOutput, to input: AVAssetWriterInput, label: String, reportsProgress: Bool) {
        let queue = DispatchQueue(label: label)
        let finished = Locked<Bool>(false)
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if finished.get() { return }
                guard let sample = self.nextSample(from: output), input.append(sample) else {
                    finished.set(true)
                    input.markAsFinished()
                    self.group.leave()
                    return
                }
                if reportsProgress { self.report(sample) }
            }
        }
    }

    private func nextSample(from output: AVAssetReaderOutput) -> CMSampleBuffer? {
        if cancelFlag.get() || source.reader.status != .reading { return nil }
        return output.copyNextSampleBuffer()
    }

    private func report(_ sample: CMSampleBuffer) {
        let pts: CMTime = CMSampleBufferGetPresentationTimeStamp(sample)
        let fraction: Double = (pts.seconds - startSeconds) / totalSeconds
        progress(Num.clamp(fraction, 0, 1))
    }

    private func finish(_ continuation: CheckedContinuation<Void, Error>) {
        let reader: AVAssetReader = source.reader
        let writer: AVAssetWriter = sink.writer
        if cancelFlag.get() {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            continuation.resume(throwing: EngineError.cancelled)
            return
        }
        if reader.status == .failed {
            writer.cancelWriting()
            continuation.resume(throwing: EngineError.exportFailed(reader.error?.localizedDescription ?? "読み込みエラー"))
            return
        }
        if writer.status == .failed {
            continuation.resume(throwing: EngineError.exportFailed(writer.error?.localizedDescription ?? "書き込みエラー"))
            return
        }
        let progress: @Sendable (Double) -> Void = self.progress
        writer.finishWriting {
            if writer.status == .completed {
                progress(1)
                continuation.resume()
            } else {
                continuation.resume(throwing: EngineError.exportFailed(writer.error?.localizedDescription ?? "保存エラー"))
            }
        }
    }
}
#endif
