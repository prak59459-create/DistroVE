#if canImport(AVFoundation)
import Accelerate
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// 音声の特徴量を Accelerate（vDSP）で作る。デバッグビルドでも速い。結果はキャッシュに保存する。
enum AudioAnalyzer {
    static func cacheURL(for asset: MediaAsset) -> URL {
        return AppPaths.cacheFolder("AudioFeatures").appendingPathComponent(asset.id.uuidString + ".bin")
    }

    static func cached(_ asset: MediaAsset) -> AudioFeatures? {
        guard let data = try? Data(contentsOf: cacheURL(for: asset)) else { return nil }
        return AudioFeatures(data: data)
    }

    static func features(for asset: MediaAsset, url: URL) async throws -> AudioFeatures {
        if let hit = cached(asset) { return hit }
        let result: AudioFeatures = try await analyze(url: url)
        try? result.serialized().write(to: cacheURL(for: asset), options: .atomic)
        return result
    }

    static func analyze(url: URL, frameRate: Double = 100) async throws -> AudioFeatures {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw EngineError.unreadable("音声がありません")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw EngineError.unreadable(reader.error?.localizedDescription ?? "audio") }
        var extractor: StreamingExtractor?
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw EngineError.cancelled
            }
            if extractor == nil {
                guard let format = CMSampleBufferGetFormatDescription(sample),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { continue }
                extractor = StreamingExtractor(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame), frameRate: frameRate)
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length: Int = CMBlockBufferGetDataLength(block)
            if length == 0 { continue }
            var floats: [Float] = Array(repeating: 0, count: length / MemoryLayout<Float>.size)
            let status: OSStatus = floats.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
            }
            if status == noErr {
                extractor?.process(interleaved: floats)
            }
        }
        if reader.status == .failed {
            throw EngineError.unreadable(reader.error?.localizedDescription ?? "audio")
        }
        guard let finished = extractor?.finish() else { throw EngineError.unreadable("音声を解析できません") }
        return finished
    }

    /// 10ms ごとの RMS・低音・最大値・K 特性を vDSP で計算する。
    final class StreamingExtractor {
        let sampleRate: Double
        let channels: Int
        let hop: Int
        private var features: AudioFeatures
        private var pending: [Float] = []
        private var lowSetup: vDSP_biquad_Setup?
        private var highSetup: vDSP_biquad_Setup?
        private var kSetup: vDSP_biquad_Setup?
        private var lowDelay: [Float] = Array(repeating: 0, count: 4)
        private var highDelay: [Float] = Array(repeating: 0, count: 4)
        private var kDelay: [Float] = Array(repeating: 0, count: 6)

        init(sampleRate: Double, channels: Int, frameRate: Double) {
            self.sampleRate = sampleRate
            self.channels = max(1, channels)
            self.hop = max(1, Int(sampleRate / frameRate))
            self.features = AudioFeatures(frameRate: sampleRate / Double(max(1, Int(sampleRate / frameRate))), sampleRate: sampleRate, channels: max(1, channels))
            let low: [Double] = StreamingExtractor.lowPass(fs: sampleRate, cutoff: 150)
            lowSetup = low.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, 1) }
            let high: [Double] = StreamingExtractor.highPass(fs: sampleRate, cutoff: 2500)
            highSetup = high.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, 1) }
            let k: [Double] = KWeightingFilter.coefficients(sampleRate: sampleRate)
            kSetup = k.withUnsafeBufferPointer { vDSP_biquad_CreateSetup($0.baseAddress!, 2) }
        }

        deinit {
            if let s = lowSetup { vDSP_biquad_DestroySetup(s) }
            if let s = highSetup { vDSP_biquad_DestroySetup(s) }
            if let s = kSetup { vDSP_biquad_DestroySetup(s) }
        }

        static func lowPass(fs: Double, cutoff: Double) -> [Double] {
            let w0: Double = 2 * Double.pi * cutoff / fs
            let alpha: Double = sin(w0) / (2 * 0.7071)
            let cosw: Double = cos(w0)
            let a0: Double = 1 + alpha
            let b0: Double = (1 - cosw) / 2 / a0
            let b1: Double = (1 - cosw) / a0
            let b2: Double = b0
            let a1: Double = -2 * cosw / a0
            let a2: Double = (1 - alpha) / a0
            return [b0, b1, b2, a1, a2]
        }

        static func highPass(fs: Double, cutoff: Double) -> [Double] {
            let w0: Double = 2 * Double.pi * min(cutoff, fs * 0.45) / fs
            let alpha: Double = sin(w0) / (2 * 0.7071)
            let cosw: Double = cos(w0)
            let a0: Double = 1 + alpha
            let b0: Double = (1 + cosw) / 2 / a0
            let b1: Double = -(1 + cosw) / a0
            let b2: Double = b0
            let a1: Double = -2 * cosw / a0
            let a2: Double = (1 - alpha) / a0
            return [b0, b1, b2, a1, a2]
        }

        func process(interleaved: [Float]) {
            let frames: Int = interleaved.count / channels
            if frames == 0 { return }
            var mono: [Float] = Array(repeating: 0, count: frames)
            interleaved.withUnsafeBufferPointer { src in
                mono.withUnsafeMutableBufferPointer { dst in
                    guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                    if channels == 1 {
                        memcpy(d, s, frames * MemoryLayout<Float>.size)
                        return
                    }
                    for c in 0..<channels {
                        vDSP_vadd(s + c, vDSP_Stride(channels), d, 1, d, 1, vDSP_Length(frames))
                    }
                    var scale: Float = 1 / Float(channels)
                    vDSP_vsmul(d, 1, &scale, d, 1, vDSP_Length(frames))
                }
            }
            pending.append(contentsOf: mono)
            consume(final: false)
        }

        private func consume(final: Bool) {
            let count: Int = (pending.count / hop) * hop
            if count == 0 { return }
            var low: [Float] = Array(repeating: 0, count: count)
            var high: [Float] = Array(repeating: 0, count: count)
            var weighted: [Float] = Array(repeating: 0, count: count)
            pending.withUnsafeBufferPointer { src in
                guard let s = src.baseAddress else { return }
                low.withUnsafeMutableBufferPointer { out in
                    if let setup = lowSetup, let o = out.baseAddress {
                        vDSP_biquad(setup, &lowDelay, s, 1, o, 1, vDSP_Length(count))
                    }
                }
                high.withUnsafeMutableBufferPointer { out in
                    if let setup = highSetup, let o = out.baseAddress {
                        vDSP_biquad(setup, &highDelay, s, 1, o, 1, vDSP_Length(count))
                    }
                }
                weighted.withUnsafeMutableBufferPointer { out in
                    if let setup = kSetup, let o = out.baseAddress {
                        vDSP_biquad(setup, &kDelay, s, 1, o, 1, vDSP_Length(count))
                    }
                }
                var frame: Int = 0
                while frame + hop <= count {
                    var rms: Float = 0
                    var peak: Float = 0
                    vDSP_rmsqv(s + frame, 1, &rms, vDSP_Length(hop))
                    vDSP_maxmgv(s + frame, 1, &peak, vDSP_Length(hop))
                    var lowRMS: Float = 0
                    var highRMS: Float = 0
                    var kPower: Float = 0
                    low.withUnsafeBufferPointer { l in
                        if let base = l.baseAddress { vDSP_rmsqv(base + frame, 1, &lowRMS, vDSP_Length(hop)) }
                    }
                    high.withUnsafeBufferPointer { h in
                        if let base = h.baseAddress { vDSP_rmsqv(base + frame, 1, &highRMS, vDSP_Length(hop)) }
                    }
                    weighted.withUnsafeBufferPointer { k in
                        if let base = k.baseAddress { vDSP_measqv(base + frame, 1, &kPower, vDSP_Length(hop)) }
                    }
                    features.rms.append(rms)
                    features.peak.append(peak)
                    features.low.append(lowRMS)
                    features.high.append(highRMS)
                    features.kWeighted.append(kPower)
                    frame += hop
                }
            }
            pending.removeFirst(count)
        }

        func finish() -> AudioFeatures {
            consume(final: true)
            return features
        }
    }
}

/// タイムラインの映像のコマ（フィルムストリップ）。
final class ThumbnailStore: @unchecked Sendable {
    static let shared = ThumbnailStore()

    struct Strip {
        let interval: Double
        let images: [CGImage]

        func image(atSeconds seconds: Double) -> CGImage? {
            if images.isEmpty { return nil }
            let index: Int = Int((seconds / max(0.001, interval)).rounded(.down))
            return images[max(0, min(images.count - 1, index))]
        }
    }

    private let strips = Locked<[UUID: Strip]>([:])
    private let loading = Locked<Set<UUID>>([])

    func strip(_ id: UUID) -> Strip? {
        return strips.get()[id]
    }

    /// まだ無ければ作る。終わったら completion をメインスレッドで呼ぶ。
    func load(_ asset: MediaAsset, height: CGFloat = 72, completion: @escaping @MainActor () -> Void) {
        if strips.get()[asset.id] != nil { return }
        let started: Bool = loading.update { set -> Bool in
            if set.contains(asset.id) { return false }
            set.insert(asset.id)
            return true
        }
        if !started { return }
        let id: UUID = asset.id
        let item: MediaAsset = asset
        Task.detached(priority: .utility) {
            let strip: Strip? = await ThumbnailStore.makeStrip(item, height: height)
            if let s = strip {
                self.strips.update { $0[id] = s }
            }
            self.loading.update { $0.remove(id) }
            await MainActor.run { completion() }
        }
    }

    func invalidate(_ id: UUID) {
        strips.update { $0[id] = nil }
    }

    static func makeStrip(_ asset: MediaAsset, height: CGFloat) async -> Strip? {
        guard let url = MediaStore.shared.url(for: asset, variant: .proxy) ?? MediaStore.shared.url(for: asset) else { return nil }
        let maxSize = CGSize(width: height * 2.5, height: height * 2.5)
        switch asset.kind {
        case .image, .gif:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(height * 2.5)
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return Strip(interval: 1_000_000, images: [image])
        case .audio:
            return nil
        case .video:
            let avAsset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maxSize
            let seconds: Double = max(0.1, asset.duration.seconds)
            let interval: Double = max(0.5, seconds / 150)
            let tolerance = CMTime(seconds: interval / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            var images: [CGImage] = []
            var t: Double = 0
            while t < seconds {
                if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)) {
                    images.append(result.image)
                } else if let last = images.last {
                    images.append(last)
                }
                t += interval
            }
            return Strip(interval: interval, images: images)
        }
    }
}
#endif
