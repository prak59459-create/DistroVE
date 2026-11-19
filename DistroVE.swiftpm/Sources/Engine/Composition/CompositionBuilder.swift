#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import Foundation

/// プロジェクトから AVFoundation の合成（映像の並び・音声のミックス・独自合成の命令）を組み立てる。
/// 映像トラックは重なりに応じて使い回し、トランジションの前後には素材の「のりしろ」を足しておく。
final class CompositionBuilder: @unchecked Sendable {
    struct Options {
        /// プレビューの縮小率（1 = キャンバスの大きさ）
        var renderScale: Double = 1
        /// 書き出しなどで大きさを直接決めるとき
        var renderSize: CGSize?
        var useProxies: Bool = false
        var fps: Double?
        var includeAudio: Bool = true

        init() {}
    }

    struct Result {
        let composition: AVComposition
        let videoComposition: AVVideoComposition
        let audioMix: AVAudioMix
        let graph: RenderGraph
        let duration: Time
    }

    private struct Loaded {
        let asset: AVURLAsset
        let video: AVAssetTrack?
        let audio: AVAssetTrack?
        let duration: Time
        let transform: CGAffineTransform
        let frameRate: Double
    }

    private struct PoolTrack {
        let track: AVMutableCompositionTrack
        var end: Time
    }

    private struct Window {
        let start: Time
        let end: Time
        let trackID: CMPersistentTrackID
    }

    let media: MediaStore
    let renderer: FrameRenderer
    private let cache = Locked<[URL: Loaded]>([:])

    init(media: MediaStore = .shared, renderer: FrameRenderer = .shared) {
        self.media = media
        self.renderer = renderer
    }

    private func load(_ url: URL) async throws -> Loaded {
        if let hit = cache.get()[url] { return hit }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime = try await asset.load(.duration)
        let videos: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .video)
        let audios: [AVAssetTrack] = try await asset.loadTracks(withMediaType: .audio)
        var transform: CGAffineTransform = .identity
        var rate: Double = 30
        if let v = videos.first {
            transform = try await v.load(.preferredTransform)
            let nominal: Float = try await v.load(.nominalFrameRate)
            if nominal > 0 { rate = Double(nominal) }
        }
        let loaded = Loaded(asset: asset, video: videos.first, audio: audios.first, duration: Time(duration), transform: transform, frameRate: rate)
        cache.update { $0[url] = loaded }
        return loaded
    }

    func forget() {
        cache.set([:])
    }

    static func renderSize(for project: Project, scale: Double) -> CGSize {
        var w: Int = Int((Double(project.canvas.width) * scale).rounded())
        var h: Int = Int((Double(project.canvas.height) * scale).rounded())
        w = max(16, w - w % 2)
        h = max(16, h - h % 2)
        return CGSize(width: w, height: h)
    }

    // MARK: 組み立て

    func build(project: Project, options: Options) async throws -> Result {
        let composition = AVMutableComposition()
        let fps: Double = options.fps ?? project.canvas.fps
        let frame: Time = Time.frameDuration(fps: fps)
        var total: Time = project.duration
        if total < frame { total = Time(seconds: 1) }

        // 土台（黒）を全体に敷く
        let fillerURL: URL = try await PlaceholderVideo.url()
        let filler: Loaded = try await load(fillerURL)
        if let fillerVideo = filler.video, let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let range = CMTimeRange(start: .zero, duration: filler.duration.cmTime)
            try base.insertTimeRange(range, of: fillerVideo, at: .zero)
            base.scaleTimeRange(CMTimeRange(start: .zero, duration: filler.duration.cmTime), toDuration: total.cmTime)
        }

        var videoPool: [PoolTrack] = []
        var windows: [Window] = []
        var layerSources: [UUID: RenderGraph.LayerSource] = [:]
        for index in project.trackIndices(of: .video) {
            let track: Track = project.tracks[index]
            if track.isHidden { continue }
            let isMain: Bool = index == project.mainTrackIndex
            for (position, clip) in track.clips.enumerated() where clip.kind == .video {
                guard let asset = project.asset(clip.mediaID) else { continue }
                let reversedURL: URL? = clip.speed.reversed ? media.url(for: asset, variant: .reversed) : nil
                let smooth: InterpolatedMedia? = reversedURL == nil ? CompositionBuilder.smoothSource(clip, asset) : nil
                let smoothURL: URL? = smooth != nil ? media.url(for: asset, variant: .interpolated) : nil
                let url: URL? = reversedURL ?? smoothURL ?? media.url(for: asset, variant: options.useProxies ? .proxy : .original)
                guard let fileURL = url, let loaded = try? await load(fileURL), let sourceTrack = loaded.video else { continue }
                var lead: Time = .zero
                var trail: Time = .zero
                if isMain {
                    if position > 0, let tr = clip.transitionIn {
                        let previous: Clip = track.clips[position - 1]
                        if previous.end == clip.start { lead = FrameRenderer.transitionHalf(tr, previous, clip) }
                    }
                    if position + 1 < track.clips.count {
                        let next: Clip = track.clips[position + 1]
                        if let tr = next.transitionIn, next.start == clip.end { trail = FrameRenderer.transitionHalf(tr, clip, next) }
                    }
                }
                let windowStart: Time = max(.zero, clip.start - lead)
                lead = clip.start - windowStart
                let windowEnd: Time = clip.end + trail
                let target: AVMutableCompositionTrack
                if let slot = videoPool.firstIndex(where: { $0.end <= windowStart }) {
                    target = videoPool[slot].track
                    videoPool[slot].end = windowEnd
                } else if let created = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    target = created
                    videoPool.append(PoolTrack(track: created, end: windowEnd))
                } else {
                    continue
                }
                let reversed: Bool = reversedURL != nil
                let mediaDuration: Time = loaded.duration
                var base: Time = clip.sourceStart
                if reversed {
                    base = max(.zero, mediaDuration - clip.sourceStart - clip.sourceDuration)
                } else if smoothURL != nil, let made = smooth {
                    // コマを足したファイルの 0 秒は素材の made.range.start
                    base = max(.zero, clip.sourceStart - made.range.start)
                }
                let mediaFrame: Time = Time.frameDuration(fps: loaded.frameRate)
                let map = SpeedMap(settings: clip.speed)
                if lead.isPositive {
                    let needed: Time = lead.scaled(map.rate(at: 0))
                    try insertHandle(target, source: sourceTrack, at: windowStart, length: lead, sourceStart: base - needed,
                                     sourceLength: needed, freezeAt: base, frame: mediaFrame, mediaDuration: mediaDuration)
                }
                try insertBody(target, source: sourceTrack, clip: clip, map: map, base: base, mediaDuration: mediaDuration)
                if trail.isPositive {
                    let sourceEnd: Time = base + clip.sourceDuration
                    let needed: Time = trail.scaled(map.rate(at: 1))
                    try insertHandle(target, source: sourceTrack, at: clip.end, length: trail, sourceStart: sourceEnd,
                                     sourceLength: needed, freezeAt: sourceEnd - mediaFrame, frame: mediaFrame, mediaDuration: mediaDuration)
                }
                layerSources[clip.id] = RenderGraph.LayerSource(trackID: target.trackID, orientation: RenderGraph.orientation(for: loaded.transform))
                windows.append(Window(start: windowStart, end: windowEnd, trackID: target.trackID))
            }
        }

        let audioMix = AVMutableAudioMix()
        if options.includeAudio {
            audioMix.inputParameters = try await buildAudio(project: project, composition: composition, useProxies: options.useProxies)
        }

        let renderSize: CGSize = options.renderSize ?? CompositionBuilder.renderSize(for: project, scale: options.renderScale)
        let graph = RenderGraph(project: project, layerSources: layerSources, renderSize: renderSize, renderer: renderer, media: media)
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = DistroCompositor.self
        videoComposition.frameDuration = frame.cmTime
        videoComposition.renderSize = renderSize
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = instructions(windows: windows, total: total, compositionDuration: composition.duration, graph: graph)
        return Result(composition: composition, videoComposition: videoComposition, audioMix: audioMix, graph: graph, duration: total)
    }

    /// なめらかスロー（Q99）で使える、コマを足したファイル。クリップの範囲をすべて含むときだけ使う。
    static func smoothSource(_ clip: Clip, _ asset: MediaAsset) -> InterpolatedMedia? {
        guard clip.speed.smooth, let made = asset.interpolated else { return nil }
        let source = TimeRange(start: clip.sourceStart, duration: clip.sourceDuration)
        return made.covers(source, factor: 1) ? made : nil
    }

    /// クリップ本体を一定速度の区間ごとに入れる。
    private func insertBody(_ target: AVMutableCompositionTrack, source: AVAssetTrack, clip: Clip, map: SpeedMap,
                            base: Time, mediaDuration: Time) throws {
        for segment in map.segments(timelineDuration: clip.duration) {
            let start: Time = base + segment.sourceOffset
            if start >= mediaDuration { break }
            var length: Time = segment.sourceDuration
            if start + length > mediaDuration { length = mediaDuration - start }
            if !length.isPositive { continue }
            let at: Time = clip.start + segment.timelineOffset
            try target.insertTimeRange(CMTimeRange(start: start.cmTime, duration: length.cmTime), of: source, at: at.cmTime)
            if length != segment.timelineDuration {
                target.scaleTimeRange(CMTimeRange(start: at.cmTime, duration: length.cmTime), toDuration: segment.timelineDuration.cmTime)
            }
        }
    }

    /// トランジション用ののりしろ。素材が足りなければ端のフレームを止めて使う。
    private func insertHandle(_ target: AVMutableCompositionTrack, source: AVAssetTrack, at: Time, length: Time,
                              sourceStart: Time, sourceLength: Time, freezeAt: Time, frame: Time, mediaDuration: Time) throws {
        var start: Time = sourceStart
        var sourceSpan: Time = sourceLength
        if start < .zero || start + sourceSpan > mediaDuration || !sourceSpan.isPositive {
            start = freezeAt.clamped(.zero, max(.zero, mediaDuration - frame))
            sourceSpan = frame
        }
        try target.insertTimeRange(CMTimeRange(start: start.cmTime, duration: sourceSpan.cmTime), of: source, at: at.cmTime)
        if sourceSpan != length {
            target.scaleTimeRange(CMTimeRange(start: at.cmTime, duration: sourceSpan.cmTime), toDuration: length.cmTime)
        }
    }

    /// 音声トラックと音量（キーフレーム・フェード・自動そろえ）を組み立てる。
    private func buildAudio(project: Project, composition: AVMutableComposition, useProxies: Bool) async throws -> [AVAudioMixInputParameters] {
        var pool: [PoolTrack] = []
        var parameters: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        for track in project.tracks where track.kind != .subtitle && !track.isMuted {
            for clip in track.clips {
                let fromVideo: Bool = clip.kind == .video && track.kind == .video
                let fromAudio: Bool = clip.kind == .audio && track.kind == .audio
                if !(fromVideo || fromAudio) { continue }
                if clip.audio.isMuted || clip.speed.reversed { continue }
                guard let asset = project.asset(clip.mediaID), asset.hasAudio else { continue }
                var url: URL?
                let processing: AudioProcessing = clip.audio.processing
                if processing.isActive && processing.isRenderedUpToDate, let path = processing.renderedPath {
                    let processed: URL = AppPaths.media.appendingPathComponent(path)
                    if FileManager.default.fileExists(atPath: processed.path) { url = processed }
                }
                if url == nil { url = media.url(for: asset, variant: useProxies ? .proxy : .original) }
                guard let fileURL = url, let loaded = try? await load(fileURL), let sourceTrack = loaded.audio else { continue }
                let target: AVMutableCompositionTrack
                if let slot = pool.firstIndex(where: { $0.end <= clip.start }) {
                    target = pool[slot].track
                    pool[slot].end = clip.end
                } else if let created = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    target = created
                    pool.append(PoolTrack(track: created, end: clip.end))
                } else {
                    continue
                }
                let map = SpeedMap(settings: clip.speed)
                try insertBody(target, source: sourceTrack, clip: clip, map: map, base: clip.sourceStart, mediaDuration: loaded.duration)
                let params: AVMutableAudioMixInputParameters = parameters[target.trackID] ?? AVMutableAudioMixInputParameters(track: target)
                params.audioTimePitchAlgorithm = clip.speed.preservePitch ? .spectral : .varispeed
                CompositionBuilder.addVolume(params, clip: clip, trackVolume: track.volume)
                parameters[target.trackID] = params
            }
        }
        return Array(parameters.values)
    }

    /// 音量の変化を AVAudioMix の直線ランプで表す。
    static func addVolume(_ params: AVMutableAudioMixInputParameters, clip: Clip, trackVolume: Double) {
        let audio: AudioSettings = clip.audio
        let duration: Time = clip.duration
        if !audio.volume.isAnimated {
            let level: Float = Float(audio.volume.value * audio.gain * trackVolume)
            var cursor: Time = .zero
            if audio.fadeIn.isPositive {
                let fade: Time = min(audio.fadeIn, duration)
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: CMTimeRange(start: clip.start.cmTime, duration: fade.cmTime))
                cursor = fade
            } else {
                params.setVolume(level, at: clip.start.cmTime)
            }
            if audio.fadeOut.isPositive {
                let fade: Time = min(audio.fadeOut, duration - cursor)
                let fadeStart: Time = clip.end - fade
                if fade.isPositive {
                    if fadeStart > clip.start + cursor {
                        params.setVolume(level, at: (clip.start + cursor).cmTime)
                    }
                    params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: CMTimeRange(start: fadeStart.cmTime, duration: fade.cmTime))
                }
            } else if cursor.isPositive {
                params.setVolume(level, at: (clip.start + cursor).cmTime)
            }
            return
        }
        // キーフレームがあるときは 0.1 秒ごとの折れ線で近似する
        let step = Time(seconds: 0.1)
        var t: Time = .zero
        var previous: Float = Float(audio.level(at: .zero, clipDuration: duration) * trackVolume)
        while t < duration {
            let next: Time = min(duration, t + step)
            let value: Float = Float(audio.level(at: next, clipDuration: duration) * trackVolume)
            params.setVolumeRamp(fromStartVolume: previous, toEndVolume: value,
                                 timeRange: CMTimeRange(start: (clip.start + t).cmTime, duration: (next - t).cmTime))
            previous = value
            t = next
        }
    }

    /// 切れ目ごとに区切った合成の命令（全体を隙間なく覆う）。
    private func instructions(windows: [Window], total: Time, compositionDuration: CMTime, graph: RenderGraph) -> [DistroInstruction] {
        var boundaries = Set<Int64>()
        boundaries.insert(0)
        boundaries.insert(total.ticks)
        for w in windows {
            boundaries.insert(max(0, min(total.ticks, w.start.ticks)))
            boundaries.insert(max(0, min(total.ticks, w.end.ticks)))
        }
        let sorted: [Int64] = boundaries.sorted()
        var result: [DistroInstruction] = []
        for i in 0..<(sorted.count - 1) {
            let a: Int64 = sorted[i]
            let b: Int64 = sorted[i + 1]
            if b <= a { continue }
            var ids: [CMPersistentTrackID] = []
            for w in windows where w.start.ticks < b && w.end.ticks > a && !ids.contains(w.trackID) {
                ids.append(w.trackID)
            }
            let range = CMTimeRange(start: Time(ticks: a).cmTime, duration: Time(ticks: b - a).cmTime)
            result.append(DistroInstruction(timeRange: range, trackIDs: ids, graph: graph))
        }
        // 合成全体の長さが計算と少しでも違えば、最後の命令を伸ばして合わせる
        if let last = result.last {
            let end: CMTime = CMTimeRangeGetEnd(last.timeRange)
            if CMTimeCompare(compositionDuration, end) > 0 {
                let extended = CMTimeRange(start: last.timeRange.start, end: compositionDuration)
                result[result.count - 1] = DistroInstruction(timeRange: extended, trackIDs: last.trackIDs, graph: graph)
            }
        }
        return result
    }
}
#endif
