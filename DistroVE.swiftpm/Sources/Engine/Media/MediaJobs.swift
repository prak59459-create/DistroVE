#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
import Foundation

/// 時間のかかる素材の処理（プロキシ・逆再生・音声の取り出し）。
enum MediaJobs {
    static func runExport(_ session: AVAssetExportSession) async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                continuation.resume()
            }
        }
        if session.status != .completed {
            throw EngineError.exportFailed(session.error?.localizedDescription ?? "export")
        }
    }

    /// 軽い代替動画（Q84: プロキシ編集）。540p の H.264 にする。戻り値は Media フォルダーからの相対パス。
    static func makeProxy(for asset: MediaAsset) async throws -> String {
        guard let url = MediaStore.shared.url(for: asset) else { throw EngineError.missingMedia(asset.name) }
        let folder: URL = AppPaths.media.appendingPathComponent("Proxies", isDirectory: true)
        AppPaths.ensure(folder)
        let output: URL = folder.appendingPathComponent(asset.id.uuidString + ".mp4")
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPreset960x540) else {
            throw EngineError.unsupported("プロキシを作れません")
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        try await runExport(session)
        return "Proxies/" + output.lastPathComponent
    }

    /// 音声だけを m4a で取り出す（文字起こし・音声加工用）。range を指定するとその区間だけ。
    static func extractAudio(from url: URL, range: TimeRange? = nil) async throws -> URL {
        let output: URL = AppPaths.cacheFolder("AudioWork").appendingPathComponent(UUID().uuidString + ".m4a")
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetAppleM4A) else {
            throw EngineError.unsupported("音声を取り出せません")
        }
        session.outputURL = output
        session.outputFileType = .m4a
        if let r = range { session.timeRange = r.cmTimeRange }
        try await runExport(session)
        return output
    }

    /// 速さを変えたクリップのコマを作る（Q99: 光学フロー・コマの合成・モーションブラー）。fps はタイムライン（または書き出し）のフレームレート。
    /// 作ったファイルは同じ条件なら同じ名前（RetimePlan.cachePath）になるので、作り直しや元に戻したときにそのまま使える。戻り値はその相対パス。
    static func makeRetimed(clip: Clip, asset: MediaAsset, fps: Double,
                            progress: (@Sendable (Double) -> Void)? = nil,
                            isCancelled: (@Sendable () -> Bool)? = nil) async throws -> String {
        let plan = RetimePlan(clip: clip, asset: asset, fps: fps)
        let target: URL = AppPaths.media.appendingPathComponent(plan.cachePath)
        if FileManager.default.fileExists(atPath: target.path) { return plan.cachePath }
        let variant: MediaStore.Variant = clip.speed.reversed ? .reversed : .original
        guard let url = MediaStore.shared.url(for: asset, variant: variant) else {
            if clip.speed.reversed { throw EngineError.unsupported("逆再生の準備ができていません") }
            throw EngineError.missingMedia(asset.name)
        }
        #if canImport(Vision)
        guard let interpolator = FrameInterpolator.shared else { throw EngineError.unsupported("この端末ではコマを作れません") }
        let folder: URL = AppPaths.media.appendingPathComponent(RetimePlan.folder, isDirectory: true)
        AppPaths.ensure(folder)
        // 途中で止めても壊れたファイルが残らないよう、別の名前で作ってから置き換える
        let working: URL = folder.appendingPathComponent("working-" + UUID().uuidString + ".mov")
        do {
            try await interpolator.render(plan: plan, url: url, accuracy: DevicePerformance.current.flowAccuracy,
                                          output: working, progress: progress, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: working)
            throw error
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: working, to: target)
        return plan.cachePath
        #else
        throw EngineError.unsupported("この端末ではコマを作れません")
        #endif
    }

    /// スムースカット（光学フローのトランジション）のコマを作る。戻り値は作ったファイルの相対パス（同じ条件なら同じ名前）。
    static func makeSmoothCut(_ plan: SmoothCutPlan, assetA: MediaAsset, assetB: MediaAsset,
                              progress: (@Sendable (Double) -> Void)? = nil,
                              isCancelled: (@Sendable () -> Bool)? = nil) async throws -> String {
        let target: URL = AppPaths.media.appendingPathComponent(plan.cachePath)
        if FileManager.default.fileExists(atPath: target.path) { return plan.cachePath }
        guard let urlA = MediaStore.shared.url(for: assetA) else { throw EngineError.missingMedia(assetA.name) }
        guard let urlB = MediaStore.shared.url(for: assetB) else { throw EngineError.missingMedia(assetB.name) }
        #if canImport(Vision)
        guard let interpolator = FrameInterpolator.shared else { throw EngineError.unsupported("この端末ではコマを作れません") }
        let folder: URL = AppPaths.media.appendingPathComponent(RetimePlan.folder, isDirectory: true)
        AppPaths.ensure(folder)
        let working: URL = folder.appendingPathComponent("working-" + UUID().uuidString + ".mov")
        do {
            try await interpolator.renderMorph(plan: plan, from: urlA, to: urlB, accuracy: DevicePerformance.current.flowAccuracy,
                                               output: working, progress: progress, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: working)
            throw error
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: working, to: target)
        return plan.cachePath
        #else
        throw EngineError.unsupported("この端末ではコマを作れません")
        #endif
    }

    /// clip を fps で再生・書き出すときに、作ったコマのファイルが要るか（コマの繰り返しで足りるなら要らない）。
    static func needsRetime(_ clip: Clip, asset: MediaAsset, fps: Double) -> Bool {
        if clip.kind != .video || !clip.speed.makesFrames { return false }
        return RetimePlan(clip: clip, asset: asset, fps: fps).isNeeded(sourceFPS: asset.frameRate)
    }

    /// 逆再生用の動画を作る（Q34）。メモリを抑えるため、後ろから短い区間ずつ読んで逆順に書く。音声は別のファイル（-audio.caf）に逆順で書く。
    static func makeReversed(for asset: MediaAsset, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        guard let url = MediaStore.shared.url(for: asset) else { throw EngineError.missingMedia(asset.name) }
        let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await avAsset.loadTracks(withMediaType: .video).first else { throw EngineError.unreadable("映像がありません") }
        let duration: Time = Time(try await avAsset.load(.duration))
        let natural: CGSize = try await track.load(.naturalSize)
        let transform: CGAffineTransform = try await track.load(.preferredTransform)
        let nominal: Float = try await track.load(.nominalFrameRate)
        let fps: Double = nominal > 0 ? Double(nominal) : 30
        let folder: URL = AppPaths.media.appendingPathComponent("Reversed", isDirectory: true)
        AppPaths.ensure(folder)
        let output: URL = folder.appendingPathComponent(asset.id.uuidString + ".mov")
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let width: Int = Int(natural.width) - Int(natural.width) % 2
        let height: Int = Int(natural.height) - Int(natural.height) % 2
        let bitrate: Int = max(2_000_000, Int(Double(width * height) * fps * 0.12))
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate]
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw EngineError.exportFailed(writer.error?.localizedDescription ?? "reverse") }
        writer.startSession(atSourceTime: .zero)
        // 1 区間で持つフレーム数をメモリ（約 120MB）から決める
        let frameBytes: Double = Double(max(1, width * height)) * 1.5
        let framesPerChunk: Double = max(4, min(60, 120_000_000 / frameBytes))
        let chunk: Time = Time(seconds: max(0.1, min(1.0, framesPerChunk / fps)))
        let frameDuration: Time = Time.frameDuration(fps: fps)
        var chunkEnd: Time = duration
        var lastWritten: Int64 = -1
        while chunkEnd > .zero {
            if Task.isCancelled {
                writer.cancelWriting()
                throw EngineError.cancelled
            }
            let chunkStart: Time = max(.zero, chunkEnd - chunk)
            let reader = try AVAssetReader(asset: avAsset)
            reader.timeRange = CMTimeRange(start: chunkStart.cmTime, end: chunkEnd.cmTime)
            let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            reader.add(readerOutput)
            reader.startReading()
            var frames: [(CVPixelBuffer, Time)] = []
            while let sample = readerOutput.copyNextSampleBuffer() {
                let pts: Time = Time(CMSampleBufferGetPresentationTimeStamp(sample))
                if pts < chunkStart || pts >= chunkEnd { continue }
                if let buffer = CMSampleBufferGetImageBuffer(sample) {
                    frames.append((buffer, pts))
                }
            }
            for (buffer, pts) in frames.reversed() {
                var outTime: Time = duration - pts - frameDuration
                if outTime.ticks <= lastWritten { outTime = Time(ticks: lastWritten + 1) }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 3_000_000)
                }
                if !adaptor.append(buffer, withPresentationTime: max(.zero, outTime).cmTime) {
                    throw EngineError.exportFailed(writer.error?.localizedDescription ?? "reverse")
                }
                lastWritten = max(0, outTime.ticks)
            }
            chunkEnd = chunkStart
            progress?(1 - chunkEnd.seconds / max(0.001, duration.seconds))
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "reverse")
        }
        let path: String = "Reversed/" + output.lastPathComponent
        if asset.hasAudio {
            let audioOutput: URL = AppPaths.media.appendingPathComponent(MediaJobs.reversedAudioPath(path))
            do {
                try await MediaJobs.makeReversedAudio(from: avAsset, duration: duration, to: audioOutput)
            } catch EngineError.cancelled {
                try? FileManager.default.removeItem(at: audioOutput)
                throw EngineError.cancelled
            } catch {
                // 音声だけ作れなかったときは、これまでどおり音なしの逆再生にする（映像は使える）
                try? FileManager.default.removeItem(at: audioOutput)
            }
        }
        return path
    }

    /// 逆再生の音声のファイル（逆再生の映像と同じ場所・名前に -audio を付ける）。
    static func reversedAudioPath(_ reversedPath: String) -> String {
        let base: String = (reversedPath as NSString).deletingPathExtension
        return base + "-audio.caf"
    }

    /// 逆再生の音声（Q34）。後ろから 5 秒ずつ読み、サンプルを逆の順に並べて CAF（PCM）に書く。
    static func makeReversedAudio(from avAsset: AVURLAsset, duration: Time, to output: URL) async throws {
        guard let track = try await avAsset.loadTracks(withMediaType: .audio).first else { return }
        let formats: [CMFormatDescription] = try await track.load(.formatDescriptions)
        var rate: Double = 48_000
        var channels: Int = 2
        if let format = formats.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            if basic.mSampleRate >= 8_000 { rate = basic.mSampleRate }
            channels = Int(basic.mChannelsPerFrame)
        }
        channels = max(1, min(2, channels))
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw EngineError.exportFailed("逆再生の音声を作れません")
        }
        try? FileManager.default.removeItem(at: output)
        let file = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var settings: [String: Any] = [:]
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 32
        settings[AVLinearPCMIsFloatKey] = true
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        settings[AVSampleRateKey] = rate
        settings[AVNumberOfChannelsKey] = channels
        var end: Double = duration.seconds
        while end > 0 {
            if Task.isCancelled { throw EngineError.cancelled }
            let start: Double = max(0, end - 5)
            let samples: [Float] = try MediaJobs.readPCM(avAsset, track: track, from: start, to: end, settings: settings)
            let frames: Int = samples.count / channels
            end = start
            if frames == 0 { continue }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            for c in 0..<channels {
                let channel: UnsafeMutablePointer<Float> = data[c]
                for f in 0..<frames {
                    channel[f] = samples[(frames - 1 - f) * channels + c]
                }
            }
            try file.write(from: buffer)
        }
    }

    /// 音声の一部を 32bit 浮動小数（チャンネル交互）で読む。
    static func readPCM(_ avAsset: AVURLAsset, track: AVAssetTrack, from start: Double, to end: Double, settings: [String: Any]) throws -> [Float] {
        let reader = try AVAssetReader(asset: avAsset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: end, preferredTimescale: 48_000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        guard reader.startReading() else { throw EngineError.unreadable(reader.error?.localizedDescription ?? "音声を読めません") }
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length: Int = CMBlockBufferGetDataLength(block)
            let count: Int = length / MemoryLayout<Float>.size
            if count == 0 { continue }
            let offset: Int = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                if let base = raw.baseAddress {
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size,
                                               destination: base + offset * MemoryLayout<Float>.size)
                }
            }
        }
        return samples
    }
}

/// 音声の加工（Q53: イコライザー・ボイスチェンジ・ノイズ除去）。AVAudioEngine の書き出しモードで端末内で処理する。
enum AudioProcessor {
    static func render(source url: URL, processing: AudioProcessing, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let audioURL: URL = try await MediaJobs.extractAudio(from: url)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let input = try AVAudioFile(forReading: audioURL)
        let format: AVAudioFormat = input.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var chain: [AVAudioNode] = [player]
        let eq = AVAudioUnitEQ(numberOfBands: 4)
        configureEQ(eq, preset: processing.eq, denoise: processing.denoise)
        engine.attach(eq)
        chain.append(eq)
        switch processing.voice {
        case .none:
            break
        case .chipmunk, .deep:
            let pitch = AVAudioUnitTimePitch()
            pitch.pitch = processing.voice == .chipmunk ? 700 : -500
            engine.attach(pitch)
            chain.append(pitch)
        case .robot, .alien, .radio:
            let distortion = AVAudioUnitDistortion()
            let preset: AVAudioUnitDistortionPreset
            switch processing.voice {
            case .robot: preset = .speechCosmicInterference
            case .alien: preset = .speechAlienChatter
            default: preset = .speechRadioTower
            }
            distortion.loadFactoryPreset(preset)
            distortion.wetDryMix = 60
            engine.attach(distortion)
            chain.append(distortion)
        case .echo:
            let delay = AVAudioUnitDelay()
            delay.delayTime = 0.22
            delay.feedback = 35
            delay.wetDryMix = 30
            engine.attach(delay)
            chain.append(delay)
        }
        for i in 0..<(chain.count - 1) {
            engine.connect(chain[i], to: chain[i + 1], format: format)
        }
        engine.connect(chain[chain.count - 1], to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        schedule(input, on: player)
        player.play()
        let folder: URL = AppPaths.media.appendingPathComponent("ProcessedAudio", isDirectory: true)
        AppPaths.ensure(folder)
        let outputURL: URL = folder.appendingPathComponent(UUID().uuidString + ".caf")
        let renderFormat: AVAudioFormat = engine.manualRenderingFormat
        // 書き込みのファイルはこの区切りの中だけで使う（抜けたところで閉じて、ノイズ除去で読み直せるようにする）
        do {
            let output = try AVAudioFile(forWriting: outputURL, settings: renderFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else {
                throw EngineError.exportFailed("音声のバッファーを作れません")
            }
            let total: AVAudioFramePosition = input.length
            var gate = NoiseGate(amount: processing.denoise, sampleRate: renderFormat.sampleRate)
            while engine.manualRenderingSampleTime < total {
                if Task.isCancelled {
                    engine.stop()
                    throw EngineError.cancelled
                }
                let remaining: AVAudioFramePosition = total - engine.manualRenderingSampleTime
                let frames: AVAudioFrameCount = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), remaining))
                let status: AVAudioEngineManualRenderingStatus = try engine.renderOffline(frames, to: buffer)
                switch status {
                case .success:
                    if processing.denoise > 0.001 && processing.denoise < 0.05 { gate.process(buffer) }
                    try output.write(from: buffer)
                case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                    continue
                case .error:
                    throw EngineError.exportFailed("音声の処理に失敗しました")
                @unknown default:
                    throw EngineError.exportFailed("音声の処理に失敗しました")
                }
                progress?(Double(engine.manualRenderingSampleTime) / Double(max(1, total)))
            }
        }
        player.stop()
        engine.stop()
        if processing.denoise >= 0.05 {
            try AudioProcessor.spectralDenoise(outputURL, strength: processing.denoise)
        }
        return "ProcessedAudio/" + outputURL.lastPathComponent
    }

    /// スペクトル減算のノイズ除去（Q53）。60 秒ずつ読み、区間ごとにノイズの形を学んで引く。
    static func spectralDenoise(_ url: URL, strength: Double) throws {
        let cleaned: URL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        // 読むファイルと書くファイルは、この区切りを抜けたところで閉じる（閉じてから入れ替える）
        do {
            let input = try AVAudioFile(forReading: url)
            let format: AVAudioFormat = input.processingFormat
            let output = try AVAudioFile(forWriting: cleaned, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk: AVAudioFrameCount = AVAudioFrameCount(format.sampleRate * 60)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return }
            while input.framePosition < input.length {
                try input.read(into: buffer, frameCount: chunk)
                let frames: Int = Int(buffer.frameLength)
                if frames == 0 { break }
                guard let channels = buffer.floatChannelData else { break }
                for c in 0..<Int(format.channelCount) {
                    let samples: [Float] = Array(UnsafeBufferPointer(start: channels[c], count: frames))
                    let result: [Float] = SpectralDenoiser.process(samples, strength: strength)
                    result.withUnsafeBufferPointer { (pointer: UnsafeBufferPointer<Float>) in
                        if let base = pointer.baseAddress { channels[c].update(from: base, count: frames) }
                    }
                }
                try output.write(from: buffer)
            }
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: cleaned, to: url)
    }

    /// 再生の予約だけをする。async 版の scheduleFile は再生し終わるまで戻らないため、
    /// オフラインで書き出すここでは使えない（同期の関数から呼んで、完了ハンドラー版を使う）。
    private static func schedule(_ file: AVAudioFile, on player: AVAudioPlayerNode) {
        player.scheduleFile(file, at: nil, completionHandler: nil)
    }

    static func configureEQ(_ eq: AVAudioUnitEQ, preset: EQPreset, denoise: Double) {
        let bands: [AVAudioUnitEQFilterParameters] = eq.bands
        for band in bands {
            band.bypass = true
        }
        func set(_ i: Int, _ type: AVAudioUnitEQFilterType, _ frequency: Float, _ gain: Float, _ bandwidth: Float = 1) {
            if i >= bands.count { return }
            bands[i].filterType = type
            bands[i].frequency = frequency
            bands[i].gain = gain
            bands[i].bandwidth = bandwidth
            bands[i].bypass = false
        }
        if denoise > 0.001 {
            // 低いうなりと高いサーッという音を抑える
            set(0, .highPass, Float(60 + 80 * denoise), 0)
            set(1, .lowPass, Float(14_000 - 5_000 * denoise), 0)
        }
        switch preset {
        case .flat:
            break
        case .voice:
            set(0, .highPass, 90, 0)
            set(2, .parametric, 3_000, 4, 1.2)
            set(3, .parametric, 250, -3, 1)
        case .bassBoost:
            set(2, .lowShelf, 120, 8)
        case .trebleBoost:
            set(2, .highShelf, 6_000, 6)
        case .lofi:
            set(0, .highPass, 300, 0)
            set(1, .lowPass, 3_500, 0)
            set(2, .parametric, 1_000, 3, 1.5)
        case .telephone:
            set(0, .highPass, 500, 0)
            set(1, .lowPass, 3_000, 0)
            set(2, .parametric, 1_500, 6, 1)
        }
    }

    /// 小さな音（雑音）をさらに下げる簡単なノイズゲート。
    struct NoiseGate {
        let threshold: Float
        let attack: Float
        let release: Float
        var envelope: Float = 0
        var gain: Float = 1

        init(amount: Double, sampleRate: Double) {
            threshold = Float(Num.linear(fromDB: -60 + 25 * amount))
            attack = Float(1 - exp(-1 / (0.005 * sampleRate)))
            release = Float(1 - exp(-1 / (0.12 * sampleRate)))
        }

        mutating func process(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData else { return }
            let frames: Int = Int(buffer.frameLength)
            let channels: Int = Int(buffer.format.channelCount)
            for i in 0..<frames {
                var level: Float = 0
                for c in 0..<channels {
                    level = max(level, abs(data[c][i]))
                }
                envelope += (level - envelope) * (level > envelope ? attack : release)
                let target: Float = envelope > threshold ? 1 : 0.1
                gain += (target - gain) * (target > gain ? attack : release)
                for c in 0..<channels {
                    data[c][i] *= gain
                }
            }
        }
    }
}
#endif
