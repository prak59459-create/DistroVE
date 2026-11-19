import Foundation

enum TrimEdge: Sendable {
    case leading
    case trailing
}

/// タイムラインの編集操作（Q32〜Q34）。すべて値型の Project を書き換えるだけなので、元に戻すは前の状態を持っておけばよい。
extension Project {
    static let defaultStillDuration: Time = Time(seconds: 3)

    var minimumClipDuration: Time {
        return frameDuration
    }

    // MARK: トラック

    func trackIndices(of kind: TrackKind) -> [Int] {
        var result: [Int] = []
        for (i, track) in tracks.enumerated() where track.kind == kind {
            result.append(i)
        }
        return result
    }

    /// 映像トラックは重なり順（下から上）の最後に、音声と字幕は末尾に足す。
    @discardableResult
    mutating func addTrack(kind: TrackKind, name: String? = nil) -> UUID {
        let count: Int = trackIndices(of: kind).count
        let title: String
        if let name = name {
            title = name
        } else {
            switch kind {
            case .video: title = count == 0 ? "メイン" : "オーバーレイ \(count)"
            case .audio: title = "オーディオ \(count + 1)"
            case .subtitle: title = "字幕 \(count + 1)"
            }
        }
        let track = Track(kind: kind, name: title)
        if kind == .video, let lastVisual = trackIndices(of: .video).last {
            tracks.insert(track, at: lastVisual + 1)
        } else {
            tracks.append(track)
        }
        return track.id
    }

    mutating func removeTrack(_ id: UUID) {
        guard let index = trackIndex(id) else { return }
        if index == mainTrackIndex { return }
        tracks.remove(at: index)
    }

    /// 同じ種類のトラックの中で重なり順を入れ替える。
    mutating func moveTrack(_ id: UUID, up: Bool) {
        guard let index = trackIndex(id) else { return }
        let kind: TrackKind = tracks[index].kind
        let same: [Int] = trackIndices(of: kind)
        guard let position = same.firstIndex(of: index) else { return }
        let targetPosition: Int = up ? position + 1 : position - 1
        if targetPosition < 0 || targetPosition >= same.count { return }
        let other: Int = same[targetPosition]
        if kind == .video && (index == mainTrackIndex || other == mainTrackIndex) { return }
        tracks.swapAt(index, other)
    }

    // MARK: クリップを作る

    func makeClip(for asset: MediaAsset) -> Clip {
        switch asset.kind {
        case .video:
            var clip = Clip(kind: .video, name: asset.name, start: .zero, duration: max(asset.duration, minimumClipDuration))
            clip.mediaID = asset.id
            return clip
        case .audio:
            var clip = Clip(kind: .audio, name: asset.name, start: .zero, duration: max(asset.duration, minimumClipDuration))
            clip.mediaID = asset.id
            return clip
        case .image:
            var clip = Clip(kind: .image, name: asset.name, start: .zero, duration: Project.defaultStillDuration)
            clip.mediaID = asset.id
            return clip
        case .gif:
            let length: Time = asset.duration.isPositive ? max(asset.duration, Time(seconds: 1)) : Project.defaultStillDuration
            var clip = Clip(kind: .gif, name: asset.name, start: .zero, duration: length)
            clip.mediaID = asset.id
            return clip
        }
    }

    // MARK: 追加

    /// メイントラックの time に一番近い切れ目へ差し込む（後ろは詰めて押し出す）。
    mutating func insertOnMain(_ clip: Clip, at time: Time) {
        guard let main = mainTrackIndex else { return }
        var item: Clip = clip
        var insertTime: Time = time
        let clips: [Clip] = tracks[main].clips
        if let index = clips.firstIndex(where: { $0.range.contains(time) }) {
            let c: Clip = clips[index]
            let middle: Time = Time(ticks: c.start.ticks + c.duration.ticks / 2)
            insertTime = time < middle ? c.start : c.end
        } else {
            insertTime = min(time, tracks[main].end)
        }
        item.start = insertTime
        shiftClips(trackIndex: main, from: insertTime, by: item.duration)
        tracks[main].clips.append(item)
        tracks[main].sortClips()
        packMainIfNeeded()
    }

    mutating func appendToMain(_ clip: Clip) {
        guard let main = mainTrackIndex else { return }
        var item: Clip = clip
        item.start = tracks[main].end
        tracks[main].clips.append(item)
    }

    /// 重ねるクリップ（PIP・テキスト・ステッカーなど）を、空いている上のトラックに置く。無ければトラックを足す。
    @discardableResult
    mutating func placeOverlay(_ clip: Clip, at time: Time) -> UUID {
        var item: Clip = clip
        item.start = max(.zero, time)
        let range: TimeRange = item.range
        let visual: [Int] = trackIndices(of: .video)
        for index in visual where index != mainTrackIndex {
            if !tracks[index].isLocked && tracks[index].isFree(range) {
                tracks[index].clips.append(item)
                tracks[index].sortClips()
                return tracks[index].id
            }
        }
        let id: UUID = addTrack(kind: .video)
        if let index = trackIndex(id) {
            tracks[index].clips.append(item)
        }
        return id
    }

    /// 音声クリップを空いている音声トラックに置く。
    @discardableResult
    mutating func placeAudio(_ clip: Clip, at time: Time) -> UUID {
        var item: Clip = clip
        item.start = max(.zero, time)
        let range: TimeRange = item.range
        for index in trackIndices(of: .audio) {
            if !tracks[index].isLocked && tracks[index].isFree(range) {
                tracks[index].clips.append(item)
                tracks[index].sortClips()
                return tracks[index].id
            }
        }
        let id: UUID = addTrack(kind: .audio)
        if let index = trackIndex(id) {
            tracks[index].clips.append(item)
        }
        return id
    }

    /// 素材を種類に合わせて置く（映像はメイン、音声は音声トラック）。
    @discardableResult
    mutating func add(asset: MediaAsset, at time: Time, asOverlay: Bool) -> UUID? {
        let clip: Clip = makeClip(for: asset)
        if asset.kind == .audio {
            placeAudio(clip, at: time)
            return clip.id
        }
        let mainEmpty: Bool = mainTrackIndex.map { tracks[$0].clips.isEmpty } ?? true
        if asOverlay && !mainEmpty {
            placeOverlay(clip, at: time)
        } else {
            insertOnMain(clip, at: time)
        }
        return clip.id
    }

    // MARK: 分割

    /// time でクリップを 2 つに分ける。戻り値は後半のクリップの ID。
    @discardableResult
    mutating func split(clipID: UUID, at time: Time) -> UUID? {
        guard let loc = locate(clipID) else { return nil }
        if tracks[loc.track].isLocked { return nil }
        let clip: Clip = tracks[loc.track].clips[loc.clip]
        let local: Time = time - clip.start
        if local < minimumClipDuration || (clip.duration - local) < minimumClipDuration { return nil }
        let parts: (Clip, Clip) = clip.splitKeyframes(at: local)
        var left: Clip = parts.0
        var right: Clip = parts.1
        let map = SpeedMap(settings: clip.speed)
        var leftCurve: [SpeedPoint] = []
        var rightCurve: [SpeedPoint] = []
        if clip.speed.hasCurve {
            let u: Double = Double(local.ticks) / Double(clip.duration.ticks)
            let boundary: Double = map.rate(at: u)
            for p in SpeedMap.normalized(clip.speed.curve) {
                if p.position < u { leftCurve.append(SpeedPoint(p.position / u, p.rate)) }
                if p.position > u { rightCurve.append(SpeedPoint((p.position - u) / (1 - u), p.rate)) }
            }
            leftCurve.append(SpeedPoint(1, boundary))
            rightCurve.insert(SpeedPoint(0, boundary), at: 0)
        }
        let sourceAtSplit: Time = map.sourceOffset(atTimeline: local, timelineDuration: clip.duration)
        left.duration = local
        left.speed.curve = leftCurve
        left.animationOut = nil
        left.audio.fadeOut = .zero
        right.id = UUID()
        right.start = time
        right.duration = clip.duration - local
        right.speed.curve = rightCurve
        right.transitionIn = nil
        right.animationIn = nil
        right.audio.fadeIn = .zero
        if clip.speed.reversed {
            // 逆再生は素材の後ろから進むので、前半が素材の後ろ側を使う
            let total: Time = clip.sourceDuration
            left.sourceStart = clip.sourceStart + (total - sourceAtSplit)
            right.sourceStart = clip.sourceStart
        } else {
            right.sourceStart = clip.sourceStart + sourceAtSplit
        }
        tracks[loc.track].clips[loc.clip] = left
        tracks[loc.track].clips.insert(right, at: loc.clip + 1)
        return right.id
    }

    /// 選択が無いときは、再生位置にあるロックされていないクリップを全トラックで分割する。
    @discardableResult
    mutating func splitAll(at time: Time) -> [UUID] {
        var created: [UUID] = []
        var ids: [UUID] = []
        for track in tracks where !track.isLocked {
            for clip in track.clips where clip.range.contains(time) {
                ids.append(clip.id)
            }
        }
        for id in ids {
            if let newID = split(clipID: id, at: time) { created.append(newID) }
        }
        return created
    }

    // MARK: 削除

    /// 削除。ripple なら後ろのクリップを詰める（Q32: リップル削除）。
    mutating func delete(clipIDs: Set<UUID>, ripple: Bool) {
        for t in tracks.indices {
            if tracks[t].isLocked { continue }
            let rippleThis: Bool = ripple || (magneticMainTrack && t == mainTrackIndex)
            var index: Int = tracks[t].clips.count - 1
            while index >= 0 {
                let clip: Clip = tracks[t].clips[index]
                if clipIDs.contains(clip.id) {
                    tracks[t].clips.remove(at: index)
                    if rippleThis {
                        shiftClips(trackIndex: t, from: clip.end, by: Time(ticks: -clip.duration.ticks))
                    }
                }
                index -= 1
            }
        }
        packMainIfNeeded()
    }

    /// time の位置にある隙間を詰める。
    mutating func closeGap(trackID: UUID, at time: Time) {
        guard let t = trackIndex(trackID) else { return }
        let clips: [Clip] = tracks[t].clips
        var previousEnd: Time = .zero
        for clip in clips {
            if time >= previousEnd && time < clip.start {
                let gap: Time = clip.start - previousEnd
                shiftClips(trackIndex: t, from: clip.start, by: Time(ticks: -gap.ticks))
                return
            }
            previousEnd = clip.end
        }
    }

    /// from 以降に始まるクリップを delta だけ動かす。
    mutating func shiftClips(trackIndex t: Int, from time: Time, by delta: Time) {
        if delta.ticks == 0 { return }
        for i in tracks[t].clips.indices where tracks[t].clips[i].start >= time {
            let moved: Time = tracks[t].clips[i].start + delta
            tracks[t].clips[i].start = max(.zero, moved)
        }
    }

    /// メイントラックを隙間なく並べ直す（マグネットがオンのとき）。
    mutating func packMainIfNeeded() {
        guard magneticMainTrack, let main = mainTrackIndex else { return }
        packTrack(main)
    }

    mutating func packTrack(_ t: Int) {
        tracks[t].sortClips()
        var cursor: Time = .zero
        for i in tracks[t].clips.indices {
            tracks[t].clips[i].start = cursor
            cursor = cursor + tracks[t].clips[i].duration
        }
    }

    // MARK: トリム

    /// 素材の長さの上限（静止画やテキストは無制限）。
    func sourceLimit(for clip: Clip) -> Time? {
        guard clip.kind.usesMediaTime, let asset = asset(clip.mediaID) else { return nil }
        return asset.duration
    }

    /// 端をドラッグして長さを変える。成功したら true。
    @discardableResult
    mutating func trim(clipID: UUID, edge: TrimEdge, to time: Time) -> Bool {
        guard let loc = locate(clipID) else { return false }
        if tracks[loc.track].isLocked { return false }
        let magnetic: Bool = magneticMainTrack && loc.track == mainTrackIndex
        var clip: Clip = tracks[loc.track].clips[loc.clip]
        let rate: Double = SpeedMap(settings: clip.speed).meanRate
        let limit: Time? = sourceLimit(for: clip)
        let minDuration: Time = minimumClipDuration
        let previousEnd: Time = loc.clip > 0 ? tracks[loc.track].clips[loc.clip - 1].end : .zero
        let nextStart: Time? = loc.clip + 1 < tracks[loc.track].clips.count ? tracks[loc.track].clips[loc.clip + 1].start : nil
        let oldDuration: Time = clip.duration

        switch edge {
        case .leading:
            var newStart: Time = min(time, clip.end - minDuration)
            if !magnetic {
                // マグネットでないときは前のクリップや 0 秒より前には動かせない（マグネット時は位置が動かないので制限しない）
                newStart = max(newStart, previousEnd)
                newStart = max(newStart, .zero)
            }
            // delta が正なら縮める、負なら伸ばす
            var delta: Time = newStart - clip.start
            if clip.kind.usesMediaTime {
                // 再生の頭側に使える素材の残り（逆再生なら素材の後ろ側）
                var extendable: Time = clip.sourceStart.scaled(1 / rate)
                if clip.speed.reversed {
                    if let limit = limit {
                        extendable = max(.zero, limit - clip.sourceEnd).scaled(1 / rate)
                    } else {
                        extendable = .zero
                    }
                }
                if delta.ticks < -extendable.ticks { delta = Time(ticks: -extendable.ticks) }
            }
            if delta.ticks == 0 { return false }
            if !clip.speed.reversed {
                clip.sourceStart = max(.zero, clip.sourceStart + delta.scaled(rate))
            }
            clip.duration = clip.duration - delta
            if !magnetic { clip.start = clip.start + delta }
            clip.shiftKeyframes(by: Time(ticks: -delta.ticks))
            clip.clampKeyframes()
            tracks[loc.track].clips[loc.clip] = clip
            if magnetic {
                shiftClips(trackIndex: loc.track, from: clip.start + oldDuration, by: Time(ticks: -delta.ticks))
            }
        case .trailing:
            var newEnd: Time = max(time, clip.start + minDuration)
            if !magnetic, let next = nextStart { newEnd = min(newEnd, next) }
            var newDuration: Time = newEnd - clip.start
            if clip.kind.usesMediaTime {
                var maxDuration: Time = newDuration
                if clip.speed.reversed {
                    // 逆再生の終わりは素材の先頭側。素材の 0 秒まで伸ばせる
                    maxDuration = clip.sourceEnd.scaled(1 / rate)
                } else if let limit = limit {
                    maxDuration = max(.zero, limit - clip.sourceStart).scaled(1 / rate)
                }
                if newDuration > maxDuration { newDuration = maxDuration }
            }
            if newDuration < minDuration { newDuration = minDuration }
            if newDuration == clip.duration { return false }
            let sourceEnd: Time = clip.sourceEnd
            clip.duration = newDuration
            if clip.speed.reversed {
                clip.sourceStart = max(.zero, sourceEnd - clip.sourceDuration)
            }
            clip.clampKeyframes()
            tracks[loc.track].clips[loc.clip] = clip
            if magnetic {
                shiftClips(trackIndex: loc.track, from: clip.start + oldDuration, by: newDuration - oldDuration)
            }
        }
        packMainIfNeeded()
        return true
    }

    // MARK: 移動・並べ替え

    /// クリップを別の位置・トラックへ動かす（Q33: ドラッグ）。重なるときは空いているトラックへ逃がす。
    @discardableResult
    mutating func move(clipID: UUID, toTrack trackID: UUID, start: Time) -> Bool {
        guard let from = locate(clipID), let target = trackIndex(trackID) else { return false }
        if tracks[from.track].isLocked || tracks[target].isLocked { return false }
        let clip: Clip = tracks[from.track].clips[from.clip]
        let targetKind: TrackKind = tracks[target].kind
        if targetKind == .subtitle { return false }
        if (clip.kind == .audio) != (targetKind == .audio) { return false }

        if magneticMainTrack && target == mainTrackIndex {
            tracks[from.track].clips.remove(at: from.clip)
            if from.track != target && magneticMainTrack && from.track == mainTrackIndex {
                packMainIfNeeded()
            }
            var item: Clip = clip
            let others: [Clip] = tracks[target].clips
            var index: Int = others.count
            for (i, other) in others.enumerated() {
                let middle: Time = Time(ticks: other.start.ticks + other.duration.ticks / 2)
                if start < middle {
                    index = i
                    break
                }
            }
            item.start = .zero
            tracks[target].clips.insert(item, at: index)
            packTrack(target)
            if from.track == mainTrackIndex || target == mainTrackIndex { packMainIfNeeded() }
            return true
        }

        var item: Clip = clip
        item.start = max(.zero, start)
        tracks[from.track].clips.remove(at: from.clip)
        if from.track == mainTrackIndex { packMainIfNeeded() }
        if tracks[target].isFree(item.range) {
            tracks[target].clips.append(item)
            tracks[target].sortClips()
            return true
        }
        if targetKind == .audio {
            placeAudio(item, at: item.start)
        } else {
            placeOverlay(item, at: item.start)
        }
        return true
    }

    /// メイントラックの並び順を変える（Q33: リスト表示での並べ替え）。
    mutating func reorderMain(clipID: UUID, toIndex newIndex: Int) {
        guard let main = mainTrackIndex, let index = tracks[main].clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip: Clip = tracks[main].clips.remove(at: index)
        let bounded: Int = max(0, min(newIndex, tracks[main].clips.count))
        tracks[main].clips.insert(clip, at: bounded)
        var cursor: Time = .zero
        if !magneticMainTrack, let first = tracks[main].clips.first { cursor = min(first.start, clip.start) }
        for i in tracks[main].clips.indices {
            tracks[main].clips[i].start = cursor
            cursor = cursor + tracks[main].clips[i].duration
        }
    }

    // MARK: 速度

    /// 一定速度にする。長さが変わった分は同じトラックの後ろを押す・詰める。
    mutating func setSpeed(clipID: UUID, rate: Double) {
        guard let loc = locate(clipID) else { return }
        var clip: Clip = tracks[loc.track].clips[loc.clip]
        let source: Time = clip.sourceDuration
        clip.speed.rate = Num.clamp(rate, SpeedSettings.minRate, SpeedSettings.maxRate)
        clip.speed.curve = []
        applySpeedChange(&clip, source: source, loc: loc)
    }

    mutating func setSpeedCurve(clipID: UUID, points: [SpeedPoint]) {
        guard let loc = locate(clipID) else { return }
        var clip: Clip = tracks[loc.track].clips[loc.clip]
        let source: Time = clip.sourceDuration
        clip.speed.curve = points.count >= 2 ? SpeedMap.normalized(points) : []
        applySpeedChange(&clip, source: source, loc: loc)
    }

    private mutating func applySpeedChange(_ clip: inout Clip, source: Time, loc: (track: Int, clip: Int)) {
        let oldDuration: Time = clip.duration
        var newDuration: Time = SpeedMap(settings: clip.speed).timelineDuration(forSource: source)
        if newDuration < minimumClipDuration { newDuration = minimumClipDuration }
        clip.duration = newDuration
        clip.clampKeyframes()
        tracks[loc.track].clips[loc.clip] = clip
        shiftClips(trackIndex: loc.track, from: clip.start + oldDuration, by: newDuration - oldDuration)
        packMainIfNeeded()
    }

    // MARK: 複製・置き換え

    @discardableResult
    mutating func duplicate(clipID: UUID) -> UUID? {
        guard let loc = locate(clipID) else { return nil }
        var copy: Clip = tracks[loc.track].clips[loc.clip]
        copy.id = UUID()
        for i in copy.effects.indices { copy.effects[i].id = UUID() }
        copy.start = copy.end
        if magneticMainTrack && loc.track == mainTrackIndex {
            shiftClips(trackIndex: loc.track, from: copy.start, by: copy.duration)
            tracks[loc.track].clips.insert(copy, at: loc.clip + 1)
            packMainIfNeeded()
            return copy.id
        }
        if tracks[loc.track].isFree(copy.range) {
            tracks[loc.track].clips.insert(copy, at: loc.clip + 1)
            tracks[loc.track].sortClips()
        } else if tracks[loc.track].kind == .audio {
            placeAudio(copy, at: copy.start)
        } else {
            placeOverlay(copy, at: copy.start)
        }
        return copy.id
    }

    /// クリップの中身（素材）だけ差し替える。長さは素材が足りる範囲で保つ。
    mutating func replaceMedia(clipID: UUID, with asset: MediaAsset) {
        guard let loc = locate(clipID) else { return }
        var clip: Clip = tracks[loc.track].clips[loc.clip]
        clip.mediaID = asset.id
        clip.name = asset.name
        clip.sourceStart = .zero
        switch asset.kind {
        case .video: clip.kind = .video
        case .image: clip.kind = .image
        case .gif: clip.kind = .gif
        case .audio: clip.kind = .audio
        }
        if asset.hasFiniteDuration {
            let available: Time = SpeedMap(settings: clip.speed).timelineDuration(forSource: asset.duration)
            if clip.duration > available { clip.duration = max(available, minimumClipDuration) }
        }
        tracks[loc.track].clips[loc.clip] = clip
        packMainIfNeeded()
    }

    /// クリップの値を書き換える（インスペクターから使う）。
    mutating func updateClip(_ id: UUID, _ change: (inout Clip) -> Void) {
        guard let loc = locate(id) else { return }
        change(&tracks[loc.track].clips[loc.clip])
    }

    /// 静止（フリーズフレーム）。time で分割し、その位置に静止画クリップを差し込む。
    @discardableResult
    mutating func insertFreezeFrame(clipID: UUID, at time: Time, image: MediaAsset, length: Time) -> UUID? {
        guard let loc = locate(clipID) else { return nil }
        let original: Clip = tracks[loc.track].clips[loc.clip]
        if !media.contains(where: { $0.id == image.id }) { media.append(image) }
        if time > original.start && time < original.end {
            split(clipID: clipID, at: time)
        }
        guard let t = trackIndex(tracks[loc.track].id) else { return nil }
        var still = Clip(kind: .image, name: "静止", start: time, duration: length)
        still.mediaID = image.id
        still.transform = original.transform
        still.fitMode = original.fitMode
        still.color = original.color
        still.look = original.look
        shiftClips(trackIndex: t, from: time, by: length)
        tracks[t].clips.append(still)
        tracks[t].sortClips()
        packMainIfNeeded()
        return still.id
    }

    // MARK: スナップ

    /// スナップ先の候補（クリップの端・再生位置・マーカー）。
    func snapCandidates(excluding: Set<UUID>, playhead: Time) -> [Time] {
        var result: [Time] = [.zero, playhead]
        for track in tracks {
            for clip in track.clips where !excluding.contains(clip.id) {
                result.append(clip.start)
                result.append(clip.end)
            }
        }
        for marker in markers {
            result.append(marker.time)
        }
        return result
    }

    /// start（と終わり）を近い候補に吸着させる（Q32: スナップ）。
    static func snap(start: Time, duration: Time, candidates: [Time], threshold: Time) -> Time {
        var best: Time = start
        var bestDistance: Int64 = threshold.ticks + 1
        let end: Time = start + duration
        for c in candidates {
            let ds: Int64 = abs(c.ticks - start.ticks)
            if ds < bestDistance {
                bestDistance = ds
                best = c
            }
            let de: Int64 = abs(c.ticks - end.ticks)
            if de < bestDistance {
                bestDistance = de
                best = c - duration
            }
        }
        return max(.zero, best)
    }

    static func snap(time: Time, candidates: [Time], threshold: Time) -> Time {
        var best: Time = time
        var bestDistance: Int64 = threshold.ticks + 1
        for c in candidates {
            let d: Int64 = abs(c.ticks - time.ticks)
            if d < bestDistance {
                bestDistance = d
                best = c
            }
        }
        return best
    }

    // MARK: 字幕

    @discardableResult
    mutating func ensureSubtitleTrack() -> Int {
        if let index = trackIndices(of: .subtitle).first { return index }
        addTrack(kind: .subtitle, name: "字幕")
        return tracks.count - 1
    }

    mutating func setCues(_ cues: [SubtitleCue], replace: Bool) {
        let index: Int = ensureSubtitleTrack()
        if replace {
            tracks[index].cues = cues
        } else {
            tracks[index].cues.append(contentsOf: cues)
        }
        tracks[index].cues.sort { $0.start < $1.start }
    }

    // MARK: マーカー

    mutating func setBeatMarkers(_ times: [Time]) {
        markers.removeAll { $0.kind == .beat }
        for t in times {
            markers.append(TimelineMarker(time: t, kind: .beat))
        }
        markers.sort { $0.time < $1.time }
    }

    mutating func toggleMarker(at time: Time, tolerance: Time) {
        if let index = markers.firstIndex(where: { $0.kind == .user && abs($0.time.ticks - time.ticks) <= tolerance.ticks }) {
            markers.remove(at: index)
            return
        }
        markers.append(TimelineMarker(time: time, kind: .user))
        markers.sort { $0.time < $1.time }
    }

    // MARK: 素材の整理

    /// どのクリップからも使われていない素材の ID。
    var unusedMediaIDs: Set<UUID> {
        var used = Set<UUID>()
        for track in tracks {
            for clip in track.clips {
                if let id = clip.mediaID { used.insert(id) }
            }
        }
        var result = Set<UUID>()
        for asset in media where !used.contains(asset.id) {
            result.insert(asset.id)
        }
        return result
    }
}
