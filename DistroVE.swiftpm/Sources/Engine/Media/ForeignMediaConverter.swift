#if canImport(AVFoundation) && canImport(VideoToolbox)
import AVFoundation
import CoreMedia
import Foundation

/// MKV・WebM・AVI を MP4（音声だけなら M4A）に変えて取り込む（Q71: FFmpeg を使わずに対応する部分）。
/// 1. 入れ物を Core の読み手で開き、映像は解読してハードウェアで H.264 / HEVC に書き直す
/// 2. 音声は端末が読める形の 1 本のファイルにする（ForeignAudioExtractor）
/// 3. 最後に映像はそのまま、音声は AAC にして 1 つのファイルにまとめる
enum ForeignMediaConverter {
    struct Result {
        let url: URL
        let kind: MediaKind
        let container: String
        let subtitles: [SubtitleCue]
        /// 読めなかったトラックなどの知らせ
        let notes: [String]
    }

    static func convert(_ source: URL, into folder: URL, progress: (@Sendable (Double) -> Void)?) async throws -> Result {
        let demuxer: ForeignDemuxer = try ForeignContainer.open(url: source)
        let work: URL = AppPaths.cacheFolder("ForeignImport").appendingPathComponent(UUID().uuidString, isDirectory: true)
        AppPaths.ensure(work)
        defer { try? FileManager.default.removeItem(at: work) }
        let videoTrack: ForeignTrack? = ForeignMediaConverter.pick(demuxer.tracks, .video)
        let subtitleTracks: [ForeignTrack] = demuxer.tracks.filter { $0.kind == .subtitle && ($0.codec == .srt || $0.codec == .ass) }
        var notes: [String] = []
        var video: VideoPass?
        if let track = videoTrack {
            video = try VideoPass(track: track, output: work.appendingPathComponent("video.mp4"), decodeOrder: demuxer is AVIReader)
        }
        // 音声は読めるものを先に試す（既定の音声が DTS でも、ほかに AC-3 などがあればそれを使う）
        var audio: ForeignAudioExtractor?
        var audioTrack: ForeignTrack?
        var unreadable: [String] = []
        for track in ForeignMediaConverter.audioCandidates(demuxer.tracks) {
            do {
                audio = try ForeignAudioExtractor(track: track, folder: work)
                audioTrack = track
                break
            } catch {
                if !unreadable.contains(track.codecLabel) { unreadable.append(track.codecLabel) }
            }
        }
        if audio == nil && !unreadable.isEmpty {
            notes.append("音声（\(unreadable.joined(separator: "・"))）はこの端末では読めないため、映像だけを取り込みました。")
        }
        if video == nil && audio == nil {
            let names: String = demuxer.tracks.map { $0.codecLabel }.joined(separator: "・")
            throw EngineError.unsupported("この \(demuxer.containerName) の中身（\(names)）は読めません")
        }
        var subtitlePackets: [Int: [ForeignPacket]] = [:]
        let total: Double = max(0.001, demuxer.duration)
        var lastReport: Double = -1
        while let packet = try demuxer.nextPacket() {
            if Task.isCancelled { throw EngineError.cancelled }
            if packet.track == videoTrack?.number, let pass = video {
                try await pass.append(packet)
            } else if packet.track == audioTrack?.number, let extractor = audio {
                do {
                    try extractor.append(packet)
                } catch {
                    audio = nil
                    notes.append("音声の途中で読めない所があったため、映像だけを取り込みました。")
                }
            } else if subtitleTracks.contains(where: { $0.number == packet.track }) {
                subtitlePackets[packet.track, default: []].append(packet)
            }
            let done: Double = min(0.85, packet.time / total * 0.85)
            if done - lastReport >= 0.01 {
                lastReport = done
                progress?(done)
            }
        }
        let videoURL: URL? = try await video?.finish()
        if let pass = video, pass.skippedFrames > 0 {
            notes.append("映像の一部（\(pass.skippedFrames) コマ）を解読できませんでした。")
        }
        let audioURL: URL? = try audio?.finish()
        let offset: Double = max(0, (audio?.firstTime ?? 0) - (video?.firstTime ?? 0))
        let kind: MediaKind = videoURL != nil ? .video : .audio
        let name: String = source.deletingPathExtension().lastPathComponent
        let output: URL = AppPaths.uniqueURL(in: folder, name: name, ext: kind == .video ? "mp4" : "m4a")
        try await ForeignMediaConverter.mux(video: videoURL, audio: audioURL, audioOffset: offset, output: output)
        progress?(1)
        let cues: [SubtitleCue] = ForeignMediaConverter.subtitles(subtitleTracks, subtitlePackets)
        return Result(url: output, kind: kind, container: demuxer.containerName, subtitles: cues, notes: notes)
    }

    /// 使うトラック（「既定」の印があるものを先に）。
    static func pick(_ tracks: [ForeignTrack], _ kind: ForeignTrackKind) -> ForeignTrack? {
        let candidates: [ForeignTrack] = tracks.filter { $0.kind == kind }
        return candidates.first { $0.isDefault } ?? candidates.first
    }

    /// 自前または端末の仕組みで読める音声
    static let readableAudio: Set<ForeignCodec> = [.aac, .mp3, .mp2, .ac3, .eac3, .flac, .pcm, .opus, .vorbis]

    /// 試す順の音声トラック：読めて「既定」の印があるもの → 読めるもの → そのほか（「既定」が先）。
    static func audioCandidates(_ tracks: [ForeignTrack]) -> [ForeignTrack] {
        let audio: [ForeignTrack] = tracks.filter { $0.kind == .audio }
        func rank(_ track: ForeignTrack) -> Int {
            let readable: Bool = readableAudio.contains(track.codec)
            return (readable ? 0 : 2) + (track.isDefault ? 0 : 1)
        }
        return audio.enumerated().sorted { a, b in
            let ra: Int = rank(a.element)
            let rb: Int = rank(b.element)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map { $0.element }
    }

    /// 字幕（日本語のトラックがあればそれ、なければ最初のもの）。
    static func subtitles(_ tracks: [ForeignTrack], _ packets: [Int: [ForeignPacket]]) -> [SubtitleCue] {
        let japanese: ForeignTrack? = tracks.first { ["jpn", "ja", "ja-JP"].contains($0.language) }
        guard let track = japanese ?? tracks.first else { return [] }
        return ForeignContainer.cues(from: packets[track.number] ?? [], codec: track.codec)
    }

    // MARK: まとめる

    /// 映像はそのまま、音声は AAC にして 1 つのファイルにする。
    static func mux(video: URL?, audio: URL?, audioOffset: Double, output: URL) async throws {
        if audio == nil, let only = video {
            try FileManager.default.moveItem(at: only, to: output)
            return
        }
        let writer = try AVAssetWriter(outputURL: output, fileType: video != nil ? .mp4 : .m4a)
        var lanes: [MuxLane] = []
        if let url = video {
            lanes.append(try await ForeignMediaConverter.videoLane(url, writer: writer))
        }
        if let url = audio {
            lanes.append(try await ForeignMediaConverter.audioLane(url, writer: writer, offset: audioOffset))
        }
        for lane in lanes where !lane.reader.startReading() {
            throw EngineError.unreadable(lane.reader.error?.localizedDescription ?? "取り込み途中のファイルを読めません")
        }
        guard writer.startWriting() else { throw EngineError.exportFailed(writer.error?.localizedDescription ?? "書き込みを始められません") }
        writer.startSession(atSourceTime: .zero)
        let job = MuxJob(lanes: lanes)
        await job.run()
        for lane in lanes where lane.reader.status == .failed {
            writer.cancelWriting()
            throw EngineError.unreadable(lane.reader.error?.localizedDescription ?? "取り込み途中のファイルを読めません")
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "取り込んだファイルを保存できません")
        }
    }

    static func videoLane(_ url: URL, writer: AVAssetWriter) async throws -> MuxLane {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EngineError.unreadable("映像がありません") }
        let formats: [CMFormatDescription] = try await track.load(.formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError.exportFailed("映像を入れられません") }
        writer.add(input)
        return MuxLane(reader: reader, output: output, input: input, offset: .zero)
    }

    static func audioLane(_ url: URL, writer: AVAssetWriter, offset: Double) async throws -> MuxLane {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw EngineError.unreadable("音声を読めません") }
        let formats: [CMFormatDescription] = try await track.load(.formatDescriptions)
        var sourceRate: Double = 48_000
        var sourceChannels: Int = 2
        if let format = formats.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            sourceRate = basic.mSampleRate
            sourceChannels = Int(basic.mChannelsPerFrame)
        }
        // AAC の書き手は、標本化周波数ごとに使えるビットレートが決まっている（22.05kHz・モノラルで 96kbps は断られる）。
        // 44.1kHz はそのまま、それ以外は 48kHz に直してから AAC にする（読み手が周波数を変える）。
        let rate: Double = sourceRate == 44_100 ? 44_100 : 48_000
        let channels: Int = max(1, min(2, sourceChannels))
        let reader = try AVAssetReader(asset: asset)
        var pcm: [String: Any] = [:]
        pcm[AVFormatIDKey] = kAudioFormatLinearPCM
        pcm[AVLinearPCMBitDepthKey] = 16
        pcm[AVLinearPCMIsFloatKey] = false
        pcm[AVLinearPCMIsBigEndianKey] = false
        pcm[AVLinearPCMIsNonInterleaved] = false
        pcm[AVSampleRateKey] = rate
        pcm[AVNumberOfChannelsKey] = channels
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: pcm)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        var aac: [String: Any] = [:]
        aac[AVFormatIDKey] = kAudioFormatMPEG4AAC
        aac[AVSampleRateKey] = rate
        aac[AVNumberOfChannelsKey] = channels
        aac[AVEncoderBitRateKey] = channels == 1 ? 96_000 : 192_000
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw EngineError.exportFailed("音声を入れられません") }
        writer.add(input)
        let shift: CMTime = offset > 0.02 ? CMTime(seconds: offset, preferredTimescale: 48_000) : .zero
        return MuxLane(reader: reader, output: output, input: input, offset: shift)
    }
}

/// まとめるときの 1 本（読み手から書き手へ）。
struct MuxLane {
    let reader: AVAssetReader
    let output: AVAssetReaderOutput
    let input: AVAssetWriterInput
    let offset: CMTime
}

/// 映像と音声を別のキューで並行に流す（書き手が交互に並べられるように）。
final class MuxJob: @unchecked Sendable {
    private let lanes: [MuxLane]
    private let group = DispatchGroup()

    init(lanes: [MuxLane]) {
        self.lanes = lanes
    }

    func run() async {
        for (index, lane) in lanes.enumerated() {
            group.enter()
            pump(lane, queue: DispatchQueue(label: "com.distrove.import.mux.\(index)"))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            group.notify(queue: DispatchQueue.global(qos: .userInitiated)) { continuation.resume() }
        }
    }

    private func pump(_ lane: MuxLane, queue: DispatchQueue) {
        let finished = Locked<Bool>(false)
        lane.input.requestMediaDataWhenReady(on: queue) {
            while lane.input.isReadyForMoreMediaData {
                if finished.get() { return }
                guard let sample = lane.output.copyNextSampleBuffer(), lane.input.append(MuxJob.shifted(sample, by: lane.offset)) else {
                    finished.set(true)
                    lane.input.markAsFinished()
                    self.group.leave()
                    return
                }
            }
        }
    }

    /// 音声の始まりが映像より遅いときに、時刻を後ろへずらす。
    static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        if offset == .zero { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        if count <= 0 { return sample }
        var timing: [CMSampleTimingInfo] = Array(repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, offset)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, offset)
            }
        }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: count,
                                              sampleTimingArray: &timing, sampleBufferOut: &copy)
        return copy ?? sample
    }
}

/// 映像を解読して、表示の順に並べ直し、ハードウェアのエンコーダーで書き直す。
final class VideoPass {
    let url: URL
    private let decoder: ForeignVideoDecoder
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pending: [ForeignVideoDecoder.Frame] = []
    private var lastTime: Double = -1
    private var written: Int = 0
    private let frameRate: Double
    private(set) var firstTime: Double?
    /// 並べ替えのために持っておくコマの数（B フレームの深さより多く）
    private static let reorderDepth: Int = 16

    init(track: ForeignTrack, output: URL, decodeOrder: Bool) throws {
        url = output
        decoder = try ForeignVideoDecoder(track: track, timesAreDecodeOrder: decodeOrder)
        frameRate = track.defaultDuration > 0 ? 1 / track.defaultDuration : 30
    }

    var skippedFrames: Int { return decoder.failedFrames }

    func append(_ packet: ForeignPacket) async throws {
        let frames: [ForeignVideoDecoder.Frame] = try decoder.decode(packet)
        try await enqueue(frames, all: false)
    }

    func finish() async throws -> URL {
        try await enqueue(decoder.flush(), all: true)
        guard let writer = writer, let input = input, written > 0 else {
            throw EngineError.unsupported("映像（\(decoder.track.codecLabel)）を解読できませんでした")
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status != .completed {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "映像を書き出せません")
        }
        return url
    }

    private func enqueue(_ frames: [ForeignVideoDecoder.Frame], all: Bool) async throws {
        pending.append(contentsOf: frames)
        pending.sort { $0.time < $1.time }
        while pending.count > (all ? 0 : VideoPass.reorderDepth) {
            let frame: ForeignVideoDecoder.Frame = pending.removeFirst()
            try await write(frame)
        }
    }

    private func write(_ frame: ForeignVideoDecoder.Frame) async throws {
        if frame.time <= lastTime { return }
        if writer == nil {
            try start(width: CVPixelBufferGetWidth(frame.image), height: CVPixelBufferGetHeight(frame.image))
        }
        guard let input = input, let adaptor = adaptor else { return }
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        if !adaptor.append(frame.image, withPresentationTime: CMTime(seconds: frame.time, preferredTimescale: 90_000)) {
            throw EngineError.exportFailed(writer?.error?.localizedDescription ?? "映像を書き出せません")
        }
        if firstTime == nil { firstTime = frame.time }
        lastTime = frame.time
        written += 1
    }

    private func start(width: Int, height: Int) throws {
        let made = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let w: Int = max(2, width - width % 2)
        let h: Int = max(2, height - height % 2)
        let codec: AVVideoCodecType = max(w, h) > 4096 ? .hevc : .h264
        let bits: Double = Double(w * h) * max(24, frameRate) * 0.12
        var compression: [String: Any] = [:]
        compression[AVVideoAverageBitRateKey] = Int(min(120_000_000, max(2_000_000, bits)))
        compression[AVVideoExpectedSourceFrameRateKey] = Int(frameRate.rounded())
        compression[AVVideoMaxKeyFrameIntervalKey] = Int((frameRate * 2).rounded())
        var settings: [String: Any] = [:]
        settings[AVVideoCodecKey] = codec
        settings[AVVideoWidthKey] = w
        settings[AVVideoHeightKey] = h
        settings[AVVideoCompressionPropertiesKey] = compression
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = false
        guard made.canAdd(videoInput) else { throw EngineError.exportFailed("映像を書き出せません") }
        made.add(videoInput)
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        guard made.startWriting() else { throw EngineError.exportFailed(made.error?.localizedDescription ?? "書き込みを始められません") }
        made.startSession(atSourceTime: .zero)
        writer = made
        input = videoInput
        adaptor = pixelAdaptor
    }
}
#endif
