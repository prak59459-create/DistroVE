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
        let size: (width: Int, height: Int) = settings.outputSize(canvasWidth: project.canvas.width, canvasHeight: project.canvas.height)
        var options = CompositionBuilder.Options()
        options.renderSize = CGSize(width: size.width, height: size.height)
        options.fps = Double(settings.fps)
        options.includeAudio = settings.includeAudio
        let built: CompositionBuilder.Result = try await builder.build(project: project, options: options)
        let composition: AVComposition = built.composition
        let range: CMTimeRange = (settings.range ?? TimeRange(start: .zero, duration: built.duration)).cmTimeRange

        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = range
        let videoTracks: [AVAssetTrack] = composition.tracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.videoComposition = built.videoComposition
        videoOutput.alwaysCopiesSampleData = false
        if reader.canAdd(videoOutput) { reader.add(videoOutput) }

        var audioOutput: AVAssetReaderAudioMixOutput?
        let audioTracks: [AVAssetTrack] = composition.tracks(withMediaType: .audio)
        if settings.includeAudio && !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = .spectral
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let bitrate: Int = settings.effectiveBitrate(width: size.width, height: size.height)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: settings.fps,
            AVVideoMaxKeyFrameIntervalKey: settings.fps * 2
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let codec: AVVideoCodecType = settings.codec == .hevc ? .hevc : .h264
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw EngineError.exportFailed("この設定では映像を書き出せません") }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ])
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard reader.startReading() else {
            throw EngineError.exportFailed(reader.error?.localizedDescription ?? "読み込みを始められません")
        }
        guard writer.startWriting() else {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "書き込みを始められません")
        }
        writer.startSession(atSourceTime: range.start)
        let totalSeconds: Double = max(0.001, range.duration.seconds)
        let startSeconds: Double = range.start.seconds
        let cancelFlag: Locked<Bool> = cancelled

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()
            let videoQueue = DispatchQueue(label: "com.distrove.export.video")
            let audioQueue = DispatchQueue(label: "com.distrove.export.audio")
            let videoFinished = Locked<Bool>(false)
            let audioFinished = Locked<Bool>(false)

            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData {
                    if videoFinished.get() { return }
                    if cancelFlag.get() || reader.status != .reading {
                        videoFinished.set(true)
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        let pts: CMTime = CMSampleBufferGetPresentationTimeStamp(sample)
                        if !videoInput.append(sample) {
                            videoFinished.set(true)
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                        progress(Num.clamp((pts.seconds - startSeconds) / totalSeconds, 0, 1))
                    } else {
                        videoFinished.set(true)
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            if let audioInput = audioInput, let audioOutput = audioOutput {
                group.enter()
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        if audioFinished.get() { return }
                        if cancelFlag.get() || reader.status != .reading {
                            audioFinished.set(true)
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            if !audioInput.append(sample) {
                                audioFinished.set(true)
                                audioInput.markAsFinished()
                                group.leave()
                                return
                            }
                        } else {
                            audioFinished.set(true)
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) {
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
#endif
