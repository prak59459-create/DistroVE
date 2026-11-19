import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 編集の操作（ツールバー・キーボード・タイムラインから呼ぶ）。
extension EditorController {
    var keyTolerance: Time {
        return Time(ticks: max(1, project.frameDuration.ticks / 2))
    }

    // MARK: カット（Q32）

    func splitAtPlayhead() {
        let t: Time = currentTime
        let ids: Set<UUID> = selectedClipIDs
        apply("分割") { p in
            if ids.isEmpty {
                if let main = p.mainTrackIndex, let clip = p.tracks[main].clips.first(where: { $0.range.contains(t) }) {
                    p.split(clipID: clip.id, at: t)
                } else {
                    p.splitAll(at: t)
                }
            } else {
                for id in ids { p.split(clipID: id, at: t) }
            }
        }
    }

    func deleteSelection(ripple: Bool) {
        if let cue = selectedCueID {
            apply("字幕を削除") { p in
                for i in p.tracks.indices { p.tracks[i].cues.removeAll { $0.id == cue } }
            }
            selectedCueID = nil
            return
        }
        let ids: Set<UUID> = selectedClipIDs
        if ids.isEmpty { return }
        apply(ripple ? "リップル削除" : "削除") { p in
            p.delete(clipIDs: ids, ripple: ripple)
        }
        selectedClipIDs = []
    }

    func duplicateSelection() {
        guard let id = selectedClipIDs.first else { return }
        var created: UUID?
        apply("複製") { p in created = p.duplicate(clipID: id) }
        if let c = created { select(c) }
    }

    func trim(_ clipID: UUID, edge: TrimEdge, to time: Time) {
        apply("トリミング", coalesce: "trim-\(clipID)-\(edge == .leading ? "l" : "r")") { p in
            p.trim(clipID: clipID, edge: edge, to: time)
        }
    }

    func move(_ clipID: UUID, to trackID: UUID, start: Time) {
        apply("移動") { p in
            p.move(clipID: clipID, toTrack: trackID, start: start)
        }
    }

    func trimToPlayhead(leading: Bool) {
        guard let clip = selectedClip else { return }
        trim(clip.id, edge: leading ? .leading : .trailing, to: currentTime)
    }

    /// スナップ先（Q32: 吸着）。
    func snapCandidates(excluding: Set<UUID>) -> [Time] {
        if !snapping { return [] }
        return project.snapCandidates(excluding: excluding, playhead: currentTime)
    }

    // MARK: 速度（Q34）

    func setSpeed(_ rate: Double) {
        guard let id = selectedClip?.id else { return }
        apply("速度", coalesce: "speed-\(id)") { p in p.setSpeed(clipID: id, rate: rate) }
    }

    func setSpeedCurve(_ points: [SpeedPoint]) {
        guard let id = selectedClip?.id else { return }
        apply("速度カーブ") { p in p.setSpeedCurve(clipID: id, points: points) }
    }

    func toggleReverse() {
        guard let clip = selectedClip, clip.kind == .video, let asset = project.asset(clip.mediaID) else { return }
        if clip.speed.reversed {
            updateSelected("逆再生を解除") { $0.speed.reversed = false }
            return
        }
        if asset.reversedPath != nil {
            updateSelected("逆再生") { $0.speed.reversed = true }
            return
        }
        let id: UUID = clip.id
        runJob("逆再生の準備") { controller, progress in
            let path: String = try await MediaJobs.makeReversed(for: asset, progress: progress)
            controller.apply("逆再生") { p in
                if let index = p.media.firstIndex(where: { $0.id == asset.id }) { p.media[index].reversedPath = path }
                p.updateClip(id) { $0.speed.reversed = true }
            }
        }
    }

    /// なめらかスロー（Q99）。コマの足りないときは、使う範囲だけをオプティカルフローで作ってから使う。
    func setSmoothSlowMotion(_ on: Bool) {
        guard let clip = selectedClip, clip.kind == .video, let asset = project.asset(clip.mediaID) else { return }
        if !on {
            updateSelected("なめらかスローを解除") { $0.speed.smooth = false }
            return
        }
        let factor: Int = clip.speed.suggestedInterpolationFactor
        let source = TimeRange(start: clip.sourceStart, duration: clip.sourceDuration)
        if let made = asset.interpolated, made.covers(source, factor: factor) {
            updateSelected("なめらかスロー") { $0.speed.smooth = true }
            return
        }
        let margin: Time = Time(seconds: 0.5)
        let start: Time = max(.zero, source.start - margin)
        let limit: Time = asset.duration.isPositive ? asset.duration : source.end + margin
        let range = TimeRange(start: start, end: min(limit, source.end + margin))
        let id: UUID = clip.id
        runJob("なめらかスローの準備") { controller, progress in
            let made: InterpolatedMedia = try await MediaJobs.makeInterpolated(for: asset, range: range, factor: factor, progress: progress)
            controller.apply("なめらかスロー") { p in
                if let index = p.media.firstIndex(where: { $0.id == asset.id }) { p.media[index].interpolated = made }
                p.updateClip(id) { $0.speed.smooth = true }
            }
        }
    }

    func freezeFrame(seconds: Double = 2) {
        guard let clip = selectedClip ?? clipUnderPlayhead(), clip.kind == .video, let asset = project.asset(clip.mediaID) else {
            showToast("動画のクリップを選んでください")
            return
        }
        let t: Time = currentTime
        let local: Time = clip.localTime(t)
        let sourceTime: Time = clip.sourceStart + SpeedMap(settings: clip.speed).sourceOffset(atTimeline: local, timelineDuration: clip.duration)
        let id: UUID = clip.id
        runJob("静止画の作成") { controller, _ in
            let image: CGImage = try await MediaStore.shared.frameImage(asset: asset, at: sourceTime)
            let still: MediaAsset = try await MediaStore.shared.saveImage(image, name: asset.name + "-静止")
            controller.apply("静止（フリーズ）") { p in
                p.insertFreezeFrame(clipID: id, at: t, image: still, length: Time(seconds: seconds))
            }
            controller.prepare(still)
        }
    }

    func clipUnderPlayhead() -> Clip? {
        guard let main = project.mainTrackIndex else { return nil }
        let t: Time = currentTime
        return project.tracks[main].clips.first { $0.range.contains(t) }
    }

    // MARK: 素材の追加（Q37, Q67）

    func addAssets(_ assets: [MediaAsset], asOverlay: Bool, autoProxy: Bool) {
        if assets.isEmpty { return }
        var cursor: Time = currentTime
        apply("素材を追加") { p in
            for asset in assets {
                if !p.media.contains(where: { $0.id == asset.id }) { p.media.append(asset) }
                if asset.kind == .audio {
                    var clip: Clip = p.makeClip(for: asset)
                    clip.start = cursor
                    p.placeAudio(clip, at: cursor)
                    continue
                }
                let mainEmpty: Bool = p.mainTrackIndex.map { p.tracks[$0].clips.isEmpty } ?? true
                if (asOverlay || asset.kind == .model3D) && !mainEmpty {
                    var clip: Clip = p.makeClip(for: asset)
                    if asset.kind != .model3D { clip.transform.scale = Param(0.5) }
                    p.placeOverlay(clip, at: cursor)
                    cursor = cursor + clip.duration
                } else {
                    let clip: Clip = p.makeClip(for: asset)
                    p.insertOnMain(clip, at: cursor)
                    cursor = cursor + clip.duration
                }
            }
        }
        for asset in assets {
            prepare(asset)
            makeProxyIfNeeded(asset, auto: autoProxy)
        }
        showToast("\(assets.count) 個の素材を追加しました")
    }

    func importFiles(_ urls: [URL], copy: Bool, asOverlay: Bool, autoProxy: Bool) {
        runJob("取り込み") { controller, progress in
            var assets: [MediaAsset] = []
            var failures: [String] = []
            for (i, url) in urls.enumerated() {
                do {
                    assets.append(try await MediaStore.shared.importFile(at: url, copy: copy))
                } catch {
                    failures.append(url.lastPathComponent + "：" + error.localizedDescription)
                }
                progress(Double(i + 1) / Double(max(1, urls.count)))
            }
            controller.addAssets(assets, asOverlay: asOverlay, autoProxy: autoProxy)
            if !failures.isEmpty {
                controller.alert = EditorAlert(title: "読み込めなかったファイル", message: failures.joined(separator: "\n"))
            }
        }
    }

    func importPhotos(_ items: [PhotosPickerItem], asOverlay: Bool, autoProxy: Bool) {
        runJob("写真から取り込み") { controller, progress in
            var assets: [MediaAsset] = []
            for (i, item) in items.enumerated() {
                if let asset = try await PhotoImport.load(item) {
                    assets.append(asset)
                }
                progress(Double(i + 1) / Double(max(1, items.count)))
            }
            controller.addAssets(assets, asOverlay: asOverlay, autoProxy: autoProxy)
        }
    }

    /// ドラッグ＆ドロップ（Q67）。
    func handleDrop(_ providers: [NSItemProvider], copy: Bool, autoProxy: Bool) -> Bool {
        let types: [UTType] = [.movie, .gif, .image, .audio]
        var accepted: Bool = false
        for provider in providers {
            guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
            accepted = true
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url = url else { return }
                let temp: URL = AppPaths.cacheFolder("Import").appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try? FileManager.default.copyItem(at: url, to: temp)
                Task { @MainActor in
                    self.importFiles([temp], copy: true, asOverlay: false, autoProxy: autoProxy)
                }
            }
        }
        return accepted
    }

    func addLibrarySound(_ id: String) {
        runJob("BGM・効果音の準備") { controller, _ in
            let asset: MediaAsset = try await SoundLibraryStore.importSound(id)
            controller.addAssets([asset], asOverlay: false, autoProxy: false)
        }
    }

    // MARK: テキスト・ステッカー・図形（Q46, Q47）

    func addText(_ preset: TextPresets.Preset) {
        var clip = Clip(kind: .text, name: preset.name, start: currentTime, duration: Time(seconds: 3))
        clip.text = preset.content
        let start: Time = currentTime
        apply("テキストを追加") { p in p.placeOverlay(clip, at: start) }
        select(clip.id)
        panel = .text
    }

    func addSticker(_ emoji: String) {
        var clip = Clip(kind: .sticker, name: emoji, start: currentTime, duration: Time(seconds: 3))
        var content = TextContent(string: emoji)
        content.size = 0.18
        content.shadowBlur = 0
        content.animation = .pop
        clip.text = content
        let start: Time = currentTime
        apply("ステッカーを追加") { p in p.placeOverlay(clip, at: start) }
        select(clip.id)
    }

    // MARK: 3D（Q50）

    func addObject3D(_ kind: Object3DKind) {
        var clip = Clip(kind: .object3D, name: kind.label, start: currentTime, duration: Time(seconds: 5))
        clip.object3D = Object3DContent(kind: kind, text: "3D")
        let start: Time = currentTime
        apply("3D を追加") { p in p.placeOverlay(clip, at: start) }
        select(clip.id)
        panel = .object3D
    }

    /// 3D モデルを素材として取り込み、重ねて置く。
    func importModel(_ url: URL) {
        runJob("3D モデルの読み込み") { controller, _ in
            let asset: MediaAsset = try await MediaStore.shared.importFile(at: url, copy: true)
            controller.addAssets([asset], asOverlay: true, autoProxy: false)
            controller.panel = .object3D
        }
    }

    /// 選んでいる 3D クリップの中身を変える。
    func update3D(_ name: String, coalesce: String? = nil, _ change: @escaping (inout Object3DContent) -> Void) {
        updateSelected(name, coalesce: coalesce) { clip in
            guard var content = clip.object3D else { return }
            change(&content)
            clip.object3D = content
            if content.kind == .text {
                clip.name = content.text.components(separatedBy: "\n").first ?? clip.name
            }
        }
    }

    func addShape(_ kind: ShapeKind) {
        var clip = Clip(kind: .shape, name: kind.label, start: currentTime, duration: Time(seconds: 3))
        clip.shape = ShapeContent(kind: kind)
        let start: Time = currentTime
        apply("図形を追加") { p in p.placeOverlay(clip, at: start) }
        select(clip.id)
    }

    /// モザイク枠（Q47）。下の映像の一部にモザイクをかける調整クリップ。
    func addMosaicBox() {
        var clip = Clip(kind: .adjustment, name: "モザイク枠", start: currentTime, duration: Time(seconds: 3))
        clip.effects = [VideoEffect(kind: .mosaic)]
        var mask = MaskSettings(shape: .rectangle)
        mask.width = Param(0.3)
        mask.height = Param(0.25)
        mask.feather = Param(0.005)
        clip.mask = mask
        let start: Time = currentTime
        apply("モザイク枠を追加") { p in p.placeOverlay(clip, at: start) }
        select(clip.id)
        panel = .mask
    }

    func addAdjustmentLayer() {
        let clip = Clip(kind: .adjustment, name: "調整レイヤー", start: currentTime, duration: Time(seconds: 5))
        let start: Time = currentTime
        apply("調整レイヤーを追加") { p in p.placeOverlay(clip, at: start) }
        select(clip.id)
        panel = .adjust
    }

    func addSolid(_ color: RGBA) {
        var clip = Clip(kind: .solid, name: "単色", start: currentTime, duration: Time(seconds: 3))
        clip.solidColor = color
        let start: Time = currentTime
        apply("単色を追加") { p in
            let mainEmpty: Bool = p.mainTrackIndex.map { p.tracks[$0].clips.isEmpty } ?? true
            if mainEmpty { p.insertOnMain(clip, at: start) } else { p.placeOverlay(clip, at: start) }
        }
        select(clip.id)
    }

    /// 手書き（Q47）。描いた画像をキャンバス全体の重ねクリップにする。
    func addDrawing(_ image: CGImage) {
        runJob("手書きの保存") { controller, _ in
            let asset: MediaAsset = try await MediaStore.shared.saveImage(image, name: "手書き")
            controller.apply("手書きを追加") { p in
                p.media.append(asset)
                var clip: Clip = p.makeClip(for: asset)
                clip.name = "手書き"
                p.placeOverlay(clip, at: controller.currentTime)
            }
            controller.prepare(asset)
        }
    }

    // MARK: トラック

    func toggleTrack(_ trackID: UUID, hidden: Bool? = nil, muted: Bool? = nil, locked: Bool? = nil) {
        apply("トラックの設定") { p in
            guard let i = p.trackIndex(trackID) else { return }
            if let h = hidden { p.tracks[i].isHidden = h }
            if let m = muted { p.tracks[i].isMuted = m }
            if let l = locked { p.tracks[i].isLocked = l }
        }
    }

    func addTrack(_ kind: TrackKind) {
        apply("トラックを追加") { p in p.addTrack(kind: kind) }
    }

    func removeTrack(_ id: UUID) {
        apply("トラックを削除") { p in p.removeTrack(id) }
    }

    // MARK: マーカー（Q59）

    func toggleMarker() {
        let t: Time = currentTime
        let tolerance: Time = Time(ticks: project.frameDuration.ticks * 2)
        apply("マーカー") { p in p.toggleMarker(at: t, tolerance: tolerance) }
    }

    // MARK: キーフレームのついたパラメーター

    func localTime(of clip: Clip) -> Time {
        return clip.localTime(currentTime)
    }

    func keyState(_ param: Param, clip: Clip) -> ParamRow.KeyState {
        if !param.isAnimated { return .none }
        return param.hasKey(at: localTime(of: clip), tolerance: keyTolerance) ? .onKey : .animated
    }

    func setParam(_ path: WritableKeyPath<Clip, Param>, _ value: Double, name: String) {
        guard let clip = selectedClip else { return }
        let local: Time = localTime(of: clip)
        let tolerance: Time = keyTolerance
        updateSelected(name, coalesce: "\(name)-\(clip.id)") { c in
            c[keyPath: path].set(value, at: local, tolerance: tolerance)
        }
    }

    func toggleKey(_ path: WritableKeyPath<Clip, Param>, name: String) {
        guard let clip = selectedClip else { return }
        let local: Time = localTime(of: clip)
        let tolerance: Time = keyTolerance
        updateSelected("キーフレーム（\(name)）") { c in
            c[keyPath: path].toggleKey(at: local, tolerance: tolerance)
        }
    }

    func resetParam(_ path: WritableKeyPath<Clip, Param>, to value: Double, name: String) {
        updateSelected("\(name)をリセット") { c in c[keyPath: path] = Param(value) }
    }

    func colorValue(_ spec: ParamSpec) -> Double {
        guard let clip = selectedClip else { return spec.defaultValue }
        return clip.color.value(spec, at: localTime(of: clip))
    }

    func setColor(_ spec: ParamSpec, _ value: Double) {
        guard let clip = selectedClip else { return }
        let local: Time = localTime(of: clip)
        let tolerance: Time = keyTolerance
        updateSelected(spec.label, coalesce: "color-\(spec.key)-\(clip.id)") { c in
            var param: Param = c.color.param(spec)
            param.set(value, at: local, tolerance: tolerance)
            c.color.set(spec, param)
        }
    }

    func toggleColorKey(_ spec: ParamSpec) {
        guard let clip = selectedClip else { return }
        let local: Time = localTime(of: clip)
        let tolerance: Time = keyTolerance
        updateSelected("キーフレーム（\(spec.label)）") { c in
            var param: Param = c.color.param(spec)
            param.toggleKey(at: local, tolerance: tolerance)
            c.color.set(spec, param)
        }
    }

    func setEffectParam(_ effectID: UUID, _ spec: ParamSpec, _ value: Double) {
        guard let clip = selectedClip else { return }
        let local: Time = localTime(of: clip)
        let tolerance: Time = keyTolerance
        updateSelected(spec.label, coalesce: "fx-\(effectID)-\(spec.key)") { c in
            guard let i = c.effects.firstIndex(where: { $0.id == effectID }) else { return }
            var param: Param = c.effects[i].params.param(spec)
            param.set(value, at: local, tolerance: tolerance)
            c.effects[i].params.set(spec, param)
        }
    }

    func toggleEffectKey(_ effectID: UUID, _ spec: ParamSpec) {
        guard let clip = selectedClip else { return }
        let local: Time = localTime(of: clip)
        let tolerance: Time = keyTolerance
        updateSelected("キーフレーム（\(spec.label)）") { c in
            guard let i = c.effects.firstIndex(where: { $0.id == effectID }) else { return }
            var param: Param = c.effects[i].params.param(spec)
            param.toggleKey(at: local, tolerance: tolerance)
            c.effects[i].params.set(spec, param)
        }
    }

    /// プレビュー上で指で動かした位置・大きさ・回転を反映する（キーフレームがあれば今の時刻のキーを更新）。
    func applyCanvasGesture(dx: Double, dy: Double, scale: Double, rotation: Double, base: Transform) {
        guard let clip = selectedClip else { return }
        let local: Time = localTime(of: clip)
        let tolerance: Time = keyTolerance
        updateSelected("変形", coalesce: "canvas-\(clip.id)") { c in
            c.transform.positionX.set(base.positionX.value(at: local) + dx, at: local, tolerance: tolerance)
            c.transform.positionY.set(base.positionY.value(at: local) + dy, at: local, tolerance: tolerance)
            c.transform.scale.set(max(0.02, base.scale.value(at: local) * scale), at: local, tolerance: tolerance)
            c.transform.rotation.set(base.rotation.value(at: local) + rotation, at: local, tolerance: tolerance)
        }
    }

    // MARK: キャンバス

    func setAspect(_ aspect: AspectPreset) {
        apply("画面サイズ") { p in
            let fps: Double = p.canvas.fps
            let background: RGBA = p.canvas.background
            let shortSide: Int = min(p.canvas.width, p.canvas.height)
            p.canvas = CanvasSettings(aspect: aspect, shortSide: max(480, shortSide), fps: fps)
            p.canvas.background = background
        }
    }

    func setFrameRate(_ fps: Double) {
        apply("フレームレート") { p in p.canvas.fps = fps }
    }

    func setBackground(_ color: RGBA) {
        apply("背景色", coalesce: "background") { p in p.canvas.background = color }
    }

    // MARK: 字幕（Q56〜Q60）

    func addCueAtPlayhead() {
        let start: Time = currentTime
        var cue = SubtitleCue(start: start, end: start + Time(seconds: 2), text: "字幕")
        cue.speaker = 0
        apply("字幕を追加") { p in
            let index: Int = p.ensureSubtitleTrack()
            p.tracks[index].cues.append(cue)
            p.tracks[index].cues.sort { $0.start < $1.start }
        }
        selectCue(cue.id)
    }

    func updateCue(_ id: UUID, name: String = "字幕", _ change: @escaping (inout SubtitleCue) -> Void) {
        apply(name, coalesce: "cue-\(id)") { p in
            for t in p.tracks.indices {
                if let i = p.tracks[t].cues.firstIndex(where: { $0.id == id }) {
                    change(&p.tracks[t].cues[i])
                    p.tracks[t].cues.sort { $0.start < $1.start }
                }
            }
        }
    }

    func updateSubtitleStyle(_ change: @escaping (inout SubtitleStyle) -> Void) {
        apply("字幕のスタイル", coalesce: "subtitle-style") { p in
            let index: Int = p.ensureSubtitleTrack()
            change(&p.tracks[index].subtitleStyle)
        }
    }

    func setSubtitleOffset(_ seconds: Double) {
        apply("字幕のずれ補正", coalesce: "subtitle-offset") { p in
            let index: Int = p.ensureSubtitleTrack()
            p.tracks[index].subtitleOffset = Time(seconds: seconds)
        }
    }

    var subtitleTrack: Track? {
        guard let index = project.trackIndices(of: .subtitle).first else { return nil }
        return project.tracks[index]
    }

    var selectedCue: SubtitleCue? {
        guard let id = selectedCueID else { return nil }
        for track in project.tracks {
            if let cue = track.cues.first(where: { $0.id == id }) { return cue }
        }
        return nil
    }

    func importSRT(_ url: URL) {
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            alert = EditorAlert(title: "SRT を読み込めません", message: url.lastPathComponent)
            return
        }
        let text: String = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) ?? ""
        let cues: [SubtitleCue] = SRT.parse(text)
        if cues.isEmpty {
            alert = EditorAlert(title: "字幕が見つかりません", message: "SRT 形式か確認してください。")
            return
        }
        apply("SRT の読み込み") { p in p.setCues(cues, replace: false) }
        showToast("\(cues.count) 件の字幕を読み込みました")
    }

    /// SRT を書き出す。戻り値は共有用のファイル。
    func exportSRT(translation: Bool) -> URL? {
        guard let track = subtitleTrack, !track.cues.isEmpty else { return nil }
        let text: String = SRT.export(track.cues, useTranslation: translation, offset: track.subtitleOffset)
        let url: URL = AppPaths.cacheFolder("Share").appendingPathComponent(AppPaths.sanitize(project.name) + (translation ? "-translated" : "") + ".srt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// .disve を共有するためのファイル。
    func projectFileForSharing() -> URL? {
        saveNow(backup: false)
        let url: URL = AppPaths.cacheFolder("Share").appendingPathComponent(AppPaths.sanitize(project.name) + "." + Project.fileExtension)
        guard let data = try? ProjectFile.encode(project, pretty: true) else { return nil }
        try? data.write(to: url, options: .atomic)
        return url
    }

    func rename(_ name: String) {
        let trimmed: String = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        apply("名前の変更") { p in p.name = trimmed }
    }

    func setMagnetic(_ on: Bool) {
        apply("マグネット") { p in
            p.magneticMainTrack = on
            p.packMainIfNeeded()
        }
    }
}

/// 写真ライブラリからの取り込み（PhotosPicker）。
enum PhotoImport {
    struct Movie: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(importedContentType: .movie) { received in
                let source: URL = received.file
                let ext: String = source.pathExtension.isEmpty ? "mov" : source.pathExtension
                let destination: URL = AppPaths.uniqueURL(in: AppPaths.cacheFolder("Import"), name: source.deletingPathExtension().lastPathComponent, ext: ext)
                try FileManager.default.copyItem(at: source, to: destination)
                return Movie(url: destination)
            }
        }
    }

    static func load(_ item: PhotosPickerItem) async throws -> MediaAsset? {
        let types: [UTType] = item.supportedContentTypes
        if types.contains(where: { $0.conforms(to: .movie) }) {
            guard let movie = try await item.loadTransferable(type: Movie.self) else { return nil }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return try await MediaStore.shared.importFile(at: movie.url, copy: true)
        }
        guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
        var ext: String = "jpg"
        if types.contains(where: { $0.conforms(to: .gif) }) {
            ext = "gif"
        } else if let first = types.first, let preferred = first.preferredFilenameExtension {
            ext = preferred
        }
        let temp: URL = AppPaths.cacheFolder("Import").appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try await MediaStore.shared.importFile(at: temp, copy: true)
    }
}
