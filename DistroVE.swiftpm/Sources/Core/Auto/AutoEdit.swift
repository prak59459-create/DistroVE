import Foundation

/// 自動編集（Q45）。解析結果を受け取ってタイムラインを組み立てる部分。解析そのものは Engine が行う。
enum AutoEdit {
    /// 切り替えの元になる素材の区間。
    struct Source: Sendable {
        var mediaID: UUID
        var name: String
        var sourceStart: Time
        var sourceDuration: Time
        var isStill: Bool
        var template: Clip?
    }

    /// BGM のビートに合わせて素材を切り替えたメイントラックを作る。
    /// beats はタイムライン上の時刻。beatsPerCut 拍ごとに次の素材へ切り替える。素材を使い回すときは続きから使う。
    static func beatSync(project: inout Project, sources: [Source], beats: [Time], beatsPerCut: Int,
                         maxDuration: Time? = nil, transition: ClipTransition? = nil, effects: [EffectKind] = []) -> Int {
        guard let main = project.mainTrackIndex, !sources.isEmpty, beats.count >= 2 else { return 0 }
        let step: Int = max(1, beatsPerCut)
        var cuts: [Time] = []
        var i: Int = 0
        while i < beats.count {
            cuts.append(beats[i])
            i += step
        }
        if let limit = maxDuration {
            cuts = cuts.filter { $0 <= limit }
        }
        if cuts.count < 2 { return 0 }
        var cursors: [Time] = []
        for s in sources { cursors.append(s.sourceStart) }
        var clips: [Clip] = []
        var position: Time = .zero
        // 最初のビートより前は 1 本目の素材で埋める
        let lead: Time = cuts[0]
        var segments: [Time] = []
        if lead.isPositive { segments.append(lead) }
        for k in 0..<(cuts.count - 1) {
            segments.append(cuts[k + 1] - cuts[k])
        }
        for (index, length) in segments.enumerated() {
            let sIndex: Int = index % sources.count
            let source: Source = sources[sIndex]
            var clip: Clip
            if let template = source.template {
                clip = template
                clip.id = UUID()
            } else {
                clip = Clip(kind: source.isStill ? .image : .video, name: source.name, start: position, duration: length)
            }
            clip.mediaID = source.mediaID
            clip.name = source.name
            clip.start = position
            clip.duration = length
            clip.speed = SpeedSettings()
            clip.transitionIn = nil
            if !source.isStill {
                let sourceEnd: Time = source.sourceStart + source.sourceDuration
                var from: Time = cursors[sIndex]
                if from + length > sourceEnd { from = source.sourceStart }
                if length > source.sourceDuration {
                    clip.duration = source.sourceDuration
                }
                clip.sourceStart = from
                cursors[sIndex] = from + clip.duration
            }
            if index > 0, let t = transition {
                let maxLength: Time = Time(ticks: min(clip.duration.ticks, clips[clips.count - 1].duration.ticks) / 2)
                clip.transitionIn = ClipTransition(kind: t.kind, duration: min(t.duration, maxLength))
            }
            for kind in effects {
                var effect = VideoEffect(kind: kind)
                effect.beatSync = kind.supportsBeatSync
                clip.effects.append(effect)
            }
            clips.append(clip)
            position = position + clip.duration
        }
        project.tracks[main].clips = clips
        project.packMainIfNeeded()
        return clips.count
    }

    /// 無音区間を切り取って詰める。silences は素材時刻（秒）。戻り値は取り除いた区間の数。
    @discardableResult
    static func cutSilences(project: inout Project, clipID: UUID, silences: [ClosedRange<Double>], minKeep: Double = 0.2) -> Int {
        guard let clip = project.clip(clipID), !clip.speed.hasCurve, !clip.speed.reversed else { return 0 }
        let rate: Double = clip.speed.rate
        var ranges: [(Time, Time)] = []
        for s in silences {
            let a: Double = (s.lowerBound - clip.sourceStart.seconds) / rate
            let b: Double = (s.upperBound - clip.sourceStart.seconds) / rate
            let lo: Double = max(0, a)
            let hi: Double = min(clip.duration.seconds, b)
            if hi - lo < minKeep { continue }
            ranges.append((clip.start + Time(seconds: lo), clip.start + Time(seconds: hi)))
        }
        if ranges.isEmpty { return 0 }
        guard let trackIndex = project.locate(clipID)?.track else { return 0 }
        let trackID: UUID = project.tracks[trackIndex].id
        var removed: Int = 0
        // 後ろから処理すると前の時刻がずれない
        for range in ranges.sorted(by: { $0.0 > $1.0 }) {
            guard let t = project.trackIndex(trackID) else { break }
            guard let target = project.tracks[t].clips.first(where: { $0.range.contains(range.0) || $0.start == range.0 }) else { continue }
            var middleID: UUID = target.id
            if range.0 > target.start {
                guard let right = project.split(clipID: target.id, at: range.0) else { continue }
                middleID = right
            }
            if let middle = project.clip(middleID), range.1 < middle.end {
                _ = project.split(clipID: middleID, at: range.1)
            }
            project.delete(clipIDs: [middleID], ripple: true)
            removed += 1
        }
        return removed
    }

    /// ハイライトだけを並べたメイントラックにする。segments は素材時刻（秒）。
    static func highlightReel(project: inout Project, source: Source, segments: [HighlightDetector.Segment]) -> Int {
        guard let main = project.mainTrackIndex, !segments.isEmpty else { return 0 }
        var clips: [Clip] = []
        var position: Time = .zero
        for seg in segments {
            var clip: Clip = source.template ?? Clip(kind: .video, name: source.name, start: position, duration: .zero)
            clip.id = UUID()
            clip.mediaID = source.mediaID
            clip.start = position
            clip.sourceStart = Time(seconds: seg.start)
            clip.duration = Time(seconds: seg.duration)
            clip.speed = SpeedSettings()
            clip.transitionIn = clips.isEmpty ? nil : ClipTransition(kind: .fade, duration: Time(seconds: 0.3))
            clips.append(clip)
            position = position + clip.duration
        }
        project.tracks[main].clips = clips
        project.packMainIfNeeded()
        return clips.count
    }

    /// 縦型ショート（9:16、既定 60 秒まで）に変換する。subjectX は素材 ID ごとの被写体の横位置（0〜1）。
    static func convertToShort(project: inout Project, maxDuration: Time = Time(seconds: 60), subjectX: [UUID: Double] = [:]) {
        let oldWidth: Double = Double(project.canvas.width)
        var canvas = CanvasSettings(aspect: .portrait9x16, shortSide: 1080, fps: project.canvas.fps)
        canvas.background = project.canvas.background
        project.canvas = canvas
        let canvasAspect: Double = Double(canvas.width) / Double(canvas.height)
        for t in project.tracks.indices {
            for c in project.tracks[t].clips.indices {
                var clip: Clip = project.tracks[t].clips[c]
                if t == project.mainTrackIndex && (clip.kind == .video || clip.kind == .image || clip.kind == .gif) {
                    clip.fitMode = .fill
                    if let mediaID = clip.mediaID, let asset = project.asset(mediaID), let sx = subjectX[mediaID] {
                        clip.transform.positionX = Param(reframeOffset(sourceAspect: asset.aspectRatio, canvasAspect: canvasAspect, subjectX: sx))
                    }
                }
                if clip.kind == .text || clip.kind == .sticker, var text = clip.text {
                    // 横長から縦長になると幅が狭くなるので、文字を少し小さくして折り返す
                    if oldWidth > Double(canvas.width) { text.size = text.size * 0.75 }
                    text.maxWidth = 0.86
                    clip.text = text
                }
                project.tracks[t].clips[c] = clip
            }
        }
        trimTimeline(project: &project, to: maxDuration)
    }

    /// 画面を埋めるように拡大した素材で、被写体が中央に来るよう横にずらす量（キャンバス幅に対する割合）。
    static func reframeOffset(sourceAspect: Double, canvasAspect: Double, subjectX: Double) -> Double {
        if sourceAspect <= canvasAspect { return 0 }
        let scaledWidth: Double = sourceAspect / canvasAspect
        let limit: Double = (scaledWidth - 1) / 2
        let desired: Double = -(subjectX - 0.5) * scaledWidth
        return Num.clamp(desired, -limit, limit)
    }

    /// limit より後ろを切り捨てる。
    static func trimTimeline(project: inout Project, to limit: Time) {
        for t in project.tracks.indices {
            var kept: [Clip] = []
            for clip in project.tracks[t].clips {
                if clip.start >= limit { continue }
                var c: Clip = clip
                if c.end > limit {
                    c.duration = limit - c.start
                    c.clampKeyframes()
                }
                kept.append(c)
            }
            project.tracks[t].clips = kept
            project.tracks[t].cues = project.tracks[t].cues.filter { $0.start < limit }
            for i in project.tracks[t].cues.indices where project.tracks[t].cues[i].end > limit {
                project.tracks[t].cues[i].end = limit
            }
        }
        project.markers = project.markers.filter { $0.time <= limit }
    }

    /// 字幕を文字起こしの単語から組み立てる（Q56: 自動文字起こし）。
    /// 句読点・間（0.6 秒以上）・最大文字数・最大長さで区切る。
    struct Word: Sendable {
        var text: String
        var start: Double
        var duration: Double

        init(text: String, start: Double, duration: Double) {
            self.text = text
            self.start = start
            self.duration = duration
        }
    }

    static func buildCues(words: [Word], offset: Time = .zero, maxCharacters: Int = 18, maxSeconds: Double = 3.5, pause: Double = 0.6) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: String = ""
        var start: Double = 0
        var end: Double = 0
        func flush() {
            let trimmed: String = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let s: Time = offset + Time(seconds: start)
                let e: Time = offset + Time(seconds: max(end, start + 0.4))
                cues.append(SubtitleCue(start: s, end: e, text: trimmed))
            }
            current = ""
        }
        for word in words {
            let gap: Double = word.start - end
            if !current.isEmpty && (gap > pause || current.count + word.text.count > maxCharacters || word.start + word.duration - start > maxSeconds) {
                flush()
            }
            if current.isEmpty { start = word.start }
            let needsSpace: Bool = !current.isEmpty && isLatin(current.last) && isLatin(word.text.first)
            current += needsSpace ? " " + word.text : word.text
            end = word.start + word.duration
            if let last = word.text.last, "。！？!?、,.".contains(last) && current.count >= maxCharacters / 2 {
                flush()
            }
        }
        flush()
        // 次の字幕と重ならないようにする
        for i in 0..<max(0, cues.count - 1) where cues[i].end > cues[i + 1].start {
            cues[i].end = cues[i + 1].start
        }
        return cues
    }

    private static func isLatin(_ ch: Character?) -> Bool {
        guard let c = ch, let scalar = c.unicodeScalars.first else { return false }
        return scalar.value < 0x3000
    }
}
