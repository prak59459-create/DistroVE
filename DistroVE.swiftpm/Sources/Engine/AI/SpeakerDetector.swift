#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// 話者の自動判別（Q57）。タイムラインで鳴る音（合成した音声）を 16kHz で少しずつ読み、字幕ごとの声の特徴で分ける。端末内で処理する。
/// 長い動画でもメモリを使いすぎないように、音声全体は持たず、字幕の真ん中の数秒だけを集めて、集まったらすぐ特徴にする。
enum SpeakerDetector {
    static let sampleRate: Double = 16_000
    /// 1 つの字幕で調べる長さ（真ん中のこの秒数だけを見る）
    static let analysisSeconds: Double = 4

    /// 調べる区間（サンプルの番号）。
    struct Window {
        let id: UUID
        let start: Int
        let end: Int
    }

    /// 字幕の ID → 話者の番号（0 から）。speakers が nil なら人数も自動で決める。
    static func assign(project: Project, speakers: Int?, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [UUID: Int] {
        let windows: [Window] = SpeakerDetector.windows(project)
        if windows.isEmpty { return [:] }
        let found: [(id: UUID, feature: [Double])] = try await SpeakerDetector.features(project, windows: windows, progress: progress)
        let labels: [Int] = SpeakerClustering.assign(found.map { $0.feature }, speakers: speakers)
        var result: [UUID: Int] = [:]
        for (item, label) in zip(found, labels) {
            result[item.id] = label
        }
        return result
    }

    /// 字幕ごとに、真ん中の analysisSeconds 秒（短い字幕は全体）を調べる区間にする。始まりの順に並べる。
    static func windows(_ project: Project) -> [Window] {
        var windows: [Window] = []
        for track in project.tracks where track.kind == .subtitle {
            let offset: Double = track.subtitleOffset.seconds
            for cue in track.cues {
                let start: Double = max(0, cue.start.seconds + offset)
                let end: Double = max(0, cue.end.seconds + offset)
                if end <= start { continue }
                let middle: Double = (start + end) / 2
                let half: Double = min((end - start) / 2, analysisSeconds / 2)
                let from: Int = Int((middle - half) * sampleRate)
                let to: Int = Int((middle + half) * sampleRate)
                if to - from < 1024 { continue }
                windows.append(Window(id: cue.id, start: from, end: to))
            }
        }
        windows.sort { $0.start < $1.start }
        return windows
    }

    /// タイムラインの音を先頭から読み、区間が読み終わるたびに声の特徴を求める。
    static func features(_ project: Project, windows: [Window], progress: (@Sendable (Double) -> Void)?) async throws -> [(id: UUID, feature: [Double])] {
        var options = CompositionBuilder.Options()
        options.includeAudio = true
        options.renderScale = 0.25
        let built: CompositionBuilder.Result = try await CompositionBuilder().build(project: project, options: options)
        let tracks: [AVAssetTrack] = built.composition.tracks(withMediaType: .audio)
        if tracks.isEmpty { throw EngineError.unsupported("音声がありません") }
        let reader = try AVAssetReader(asset: built.composition)
        var settings: [String: Any] = [:]
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        settings[AVLinearPCMBitDepthKey] = 32
        settings[AVLinearPCMIsFloatKey] = true
        settings[AVLinearPCMIsBigEndianKey] = false
        settings[AVLinearPCMIsNonInterleaved] = false
        settings[AVSampleRateKey] = sampleRate
        settings[AVNumberOfChannelsKey] = 1
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.audioMix = built.audioMix
        reader.add(output)
        guard reader.startReading() else { throw EngineError.unreadable(reader.error?.localizedDescription ?? "音声を読めません") }

        let total: Double = max(1, built.duration.seconds * sampleRate)
        var results: [(id: UUID, feature: [Double])] = []
        var active: [Int: [Float]] = [:]
        var next: Int = 0
        var position: Int = 0
        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw EngineError.cancelled
            }
            let chunk: [Float] = SpeakerDetector.floats(sample)
            if chunk.isEmpty { continue }
            let chunkEnd: Int = position + chunk.count
            while next < windows.count && windows[next].start < chunkEnd {
                active[next] = []
                next += 1
            }
            var finished: [Int] = []
            for index in active.keys.sorted() {
                let window: Window = windows[index]
                let from: Int = max(window.start, position)
                let to: Int = min(window.end, chunkEnd)
                if to > from {
                    active[index]?.append(contentsOf: chunk[(from - position)..<(to - position)])
                }
                if window.end <= chunkEnd { finished.append(index) }
            }
            for index in finished {
                if let samples = active.removeValue(forKey: index), let feature = SpeakerClustering.features(samples, sampleRate: sampleRate) {
                    results.append((windows[index].id, feature))
                }
            }
            position = chunkEnd
            progress?(min(1, Double(position) / total))
            if next >= windows.count && active.isEmpty {
                reader.cancelReading()
                break
            }
        }
        // 音が先に終わったときは、集まった分だけで調べる
        for index in active.keys.sorted() {
            if let samples = active[index], let feature = SpeakerClustering.features(samples, sampleRate: sampleRate) {
                results.append((windows[index].id, feature))
            }
        }
        if reader.status == .failed {
            throw EngineError.unreadable(reader.error?.localizedDescription ?? "音声を読めません")
        }
        return results
    }

    /// 1 つの塊の 32bit 浮動小数のサンプル。
    private static func floats(_ sample: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let count: Int = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
        if count == 0 { return [] }
        var values: [Float] = Array(repeating: 0, count: count)
        values.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            if let base = raw.baseAddress {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: base)
            }
        }
        return values
    }
}
#endif
