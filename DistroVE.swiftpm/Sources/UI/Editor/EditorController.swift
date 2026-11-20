import AVFoundation
import Combine
import SwiftUI

/// 再生位置。毎秒何十回も変わるので、編集画面全体を作り直さないよう独立させる。
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time: Time = .zero
}

/// 画面下のパネル（インスペクター）。
enum EditorPanel: String, Identifiable {
    case media
    case audioLibrary
    case text
    case stickers
    case effects
    case filters
    case adjust
    case transform
    case speed
    case volume
    case audioFX
    case transition
    case animation
    case mask
    case chroma
    case blend
    case subtitles
    case ai
    case canvas
    case keyframes
    case reorder
    case drawing
    case object3D

    var id: String { return rawValue }

    var title: String {
        switch self {
        case .media: return "素材"
        case .audioLibrary: return "BGM・効果音"
        case .text: return "テキスト"
        case .stickers: return "ステッカー・図形"
        case .object3D: return "3D"
        case .effects: return "エフェクト"
        case .filters: return "フィルター"
        case .adjust: return "色の調整"
        case .transform: return "変形"
        case .speed: return "速度"
        case .volume: return "音量"
        case .audioFX: return "音声の加工"
        case .transition: return "トランジション"
        case .animation: return "アニメーション"
        case .mask: return "マスク"
        case .chroma: return "クロマキー"
        case .blend: return "不透明度・ブレンド"
        case .subtitles: return "字幕"
        case .ai: return "AI ツール"
        case .canvas: return "画面サイズ・背景"
        case .keyframes: return "キーフレーム"
        case .reorder: return "並べ替え"
        case .drawing: return "手書き"
        }
    }
}

enum PreviewQuality: String, CaseIterable, Identifiable {
    case full
    case half
    case quarter

    var id: String { return rawValue }

    /// 端末の性能（Q81）に合わせた最初の画質。
    static var forDevice: PreviewQuality {
        return DevicePerformance.current.profile.previewScale < 0.75 ? .half : .full
    }

    var scale: Double {
        switch self {
        case .full: return 1
        case .half: return 0.5
        case .quarter: return 0.25
        }
    }

    var label: String {
        switch self {
        case .full: return "原寸"
        case .half: return "1/2"
        case .quarter: return "1/4"
        }
    }
}

/// 時間のかかる処理の進み具合。
struct JobState: Equatable {
    var title: String
    var progress: Double
}

struct EditorAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 編集画面の状態と操作。すべての変更は apply を通し、元に戻す・自動保存・プレビュー更新をまとめて行う。
@MainActor
final class EditorController: ObservableObject {
    @Published private(set) var project: Project
    @Published private(set) var revision: Int = 0
    @Published var selectedClipIDs: Set<UUID> = []
    @Published var selectedCueID: UUID?
    @Published var panel: EditorPanel?
    @Published private(set) var isPlaying: Bool = false
    @Published var loop: Bool = false
    @Published var quality: PreviewQuality = PreviewQuality.forDevice {
        didSet { requestRebuild() }
    }
    @Published var useProxies: Bool = false {
        didSet { requestRebuild() }
    }
    @Published private(set) var job: JobState?
    @Published var toast: String?
    @Published var alert: EditorAlert?
    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false
    @Published var zoom: Double = 80
    @Published private(set) var isSaving: Bool = false
    @Published private(set) var reducedForThermal: Bool = false
    @Published var snapping: Bool = true

    let clock = PlaybackClock()
    let player = AVPlayer()
    let limits: DeviceLimits
    private let history: UndoHistory
    private let builder = CompositionBuilder()
    private var graph: RenderGraph?
    private var builtKey: TimingKey?
    private var rebuildTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var lastBackup: Date = Date()
    private var observers: [NSObjectProtocol] = []
    private var isScrubbing: Bool = false

    init(project: Project) {
        self.project = project
        self.limits = DeviceCapability.limits()
        self.history = UndoHistory(spillDirectory: AppPaths.cacheFolder("Undo").appendingPathComponent(project.id.uuidString))
        player.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 20)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time)
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkThermal() }
        })
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        })
        ProjectStore.shared.markEditing(project.id)
        checkThermal()
        prepareMedia()
        requestRebuild(immediately: true)
    }

    func close() {
        player.pause()
        rebuildTask?.cancel()
        jobTask?.cancel()
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        timeObserver = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        saveNow(backup: false)
        saveThumbnail()
        ProjectStore.shared.markClosed()
        MediaStore.shared.closeReferences()
    }

    // MARK: 選択

    var selectedClip: Clip? {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return nil }
        return project.clip(id)
    }

    var selectedTrackIndex: Int? {
        guard let id = selectedClipIDs.first else { return nil }
        return project.locate(id)?.track
    }

    func select(_ clipID: UUID?, additive: Bool = false) {
        selectedCueID = nil
        guard let id = clipID else {
            selectedClipIDs = []
            return
        }
        if additive {
            if selectedClipIDs.contains(id) { selectedClipIDs.remove(id) } else { selectedClipIDs.insert(id) }
        } else {
            selectedClipIDs = [id]
        }
    }

    func selectCue(_ id: UUID?) {
        selectedClipIDs = []
        selectedCueID = id
        if id != nil { panel = .subtitles }
    }

    // MARK: 変更の入口

    /// プロジェクトを変える唯一の入口。coalesce を渡すと、続けて行うスライダー操作を 1 回の「元に戻す」にまとめる。
    func apply(_ name: String, coalesce: String? = nil, _ change: (inout Project) -> Void) {
        history.record(before: project, name: name, coalesceKey: coalesce)
        var next: Project = project
        change(&next)
        next.modifiedAt = Date()
        project = next
        didChange()
        Diagnostics.shared.count(name)
    }

    /// 選択中のクリップだけを変える。
    func updateSelected(_ name: String, coalesce: String? = nil, _ change: @escaping (inout Clip) -> Void) {
        let ids: Set<UUID> = selectedClipIDs
        if ids.isEmpty { return }
        apply(name, coalesce: coalesce) { p in
            for id in ids {
                p.updateClip(id, change)
            }
        }
    }

    private func didChange() {
        revision += 1
        canUndo = history.canUndo
        canRedo = history.canRedo
        let valid: Set<UUID> = selectedClipIDs.filter { project.clip($0) != nil }
        if valid != selectedClipIDs { selectedClipIDs = valid }
        requestRebuild()
        scheduleAutosave()
    }

    func undo() {
        guard let previous = history.undo(current: project) else { return }
        project = previous
        didChange()
        showToast("元に戻しました")
    }

    func redo() {
        guard let next = history.redo(current: project) else { return }
        project = next
        didChange()
        showToast("やり直しました")
    }

    var undoName: String? { return history.undoName }

    // MARK: 保存（Q39）

    private func scheduleAutosave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            self?.saveNow(backup: false)
        }
    }

    func saveNow(backup: Bool) {
        let snapshot: Project = project
        do {
            try ProjectStore.shared.save(snapshot)
        } catch {
            alert = EditorAlert(title: "保存できませんでした", message: error.localizedDescription)
            Diagnostics.shared.log("save failed: \(error)")
            return
        }
        if backup || Date().timeIntervalSince(lastBackup) > 300 {
            ProjectStore.shared.backup(snapshot)
            lastBackup = Date()
        }
    }

    func manualSave() {
        saveNow(backup: true)
        saveThumbnail()
        showToast("保存しました")
    }

    func saveThumbnail() {
        let snapshot: Project = project
        let time: Time = min(Time(seconds: 1), snapshot.duration)
        Task.detached(priority: .utility) {
            if let image = try? await Exporter().still(project: snapshot, at: time, maxSide: 480) {
                ProjectStore.shared.saveThumbnail(image, for: snapshot.id)
            }
        }
    }

    // MARK: プレビュー

    var currentTime: Time { return clock.time }

    private func checkThermal() {
        let reduce: Bool = DeviceCapability.shouldReduceLoad
        if reduce != reducedForThermal {
            reducedForThermal = reduce
            requestRebuild()
            if reduce { showToast("端末が熱いので、プレビューを軽くしています") }
        }
    }

    private var effectiveScale: Double {
        var scale: Double = quality.scale
        if reducedForThermal { scale = min(scale, 0.5) }
        // 4K キャンバスは原寸でも 1080p 相当でプレビューする
        let longSide: Double = Double(max(project.canvas.width, project.canvas.height))
        if longSide * scale > 1920 { scale = 1920 / longSide }
        return scale
    }

    func requestRebuild(immediately: Bool = false) {
        let key = TimingKey(project: project, scale: effectiveScale, proxies: useProxies)
        if !immediately, key == builtKey, let graph = graph {
            graph.update(project: project)
            refreshFrame()
            return
        }
        rebuildTask?.cancel()
        let snapshot: Project = project
        let scale: Double = effectiveScale
        let proxies: Bool = useProxies
        rebuildTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if Task.isCancelled { return }
            await self?.rebuild(snapshot, key: key, scale: scale, proxies: proxies)
        }
    }

    private func rebuild(_ snapshot: Project, key: TimingKey, scale: Double, proxies: Bool) async {
        var options = CompositionBuilder.Options()
        options.renderScale = scale
        options.useProxies = proxies
        do {
            let result: CompositionBuilder.Result = try await builder.build(project: snapshot, options: options)
            if Task.isCancelled { return }
            let item = AVPlayerItem(asset: result.composition)
            item.videoComposition = result.videoComposition
            item.audioMix = result.audioMix
            item.audioTimePitchAlgorithm = .spectral
            let resume: Bool = isPlaying
            let time: Time = min(clock.time, max(.zero, result.duration - snapshot.frameDuration))
            player.replaceCurrentItem(with: item)
            graph = result.graph
            builtKey = key
            if result.graph.snapshot.project.modifiedAt != project.modifiedAt {
                result.graph.update(project: project)
            }
            _ = await player.seek(to: time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            if resume { player.play() }
        } catch {
            Diagnostics.shared.log("preview build failed: \(error)")
            showToast("プレビューを作れませんでした：\(error.localizedDescription)")
        }
    }

    /// 止まっているとき、今のコマを描き直す。
    func refreshFrame() {
        if isPlaying { return }
        player.seek(to: clock.time.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: 再生（Q40）

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        let end: Time = playEnd
        if clock.time >= end - project.frameDuration {
            seek(to: playStart)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    var playStart: Time { return project.playRange?.start ?? .zero }
    var playEnd: Time { return project.playRange?.end ?? project.duration }

    /// precise が false のときは近いキーフレームで止める（スクラブ中に軽くする）。
    func seek(to time: Time, precise: Bool = true) {
        let clamped: Time = time.clamped(.zero, max(.zero, project.duration))
        clock.time = clamped
        let tolerance: CMTime = precise ? .zero : CMTime(value: 1, timescale: 10)
        player.seek(to: clamped.cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func beginScrub() {
        isScrubbing = true
        if isPlaying { pause() }
    }

    func endScrub() {
        isScrubbing = false
        seek(to: clock.time, precise: true)
    }

    func step(_ frames: Int) {
        pause()
        let frame: Time = project.frameDuration
        seek(to: clock.time + Time(ticks: frame.ticks * Int64(frames)))
    }

    private func tick(_ time: CMTime) {
        if isScrubbing || !isPlaying { return }
        let t = Time(time)
        clock.time = t
        let end: Time = playEnd
        if t >= end {
            if loop {
                seek(to: playStart)
                player.play()
            } else {
                pause()
            }
        }
    }

    private func didReachEnd() {
        if loop {
            seek(to: playStart)
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    func setInPoint() {
        let t: Time = clock.time
        apply("範囲の開始") { p in
            let end: Time = p.playRange?.end ?? p.duration
            p.playRange = end > t ? TimeRange(start: t, end: end) : nil
        }
    }

    func setOutPoint() {
        let t: Time = clock.time
        apply("範囲の終了") { p in
            let start: Time = p.playRange?.start ?? .zero
            p.playRange = t > start ? TimeRange(start: start, end: t) : nil
        }
    }

    func clearRange() {
        apply("範囲の解除") { p in p.playRange = nil }
    }

    // MARK: お知らせ・処理中の表示

    func showToast(_ text: String) {
        toast = text
        let current: String = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self?.toast == current { self?.toast = nil }
        }
    }

    /// 時間のかかる処理を 1 つずつ走らせる。
    func runJob(_ title: String, _ work: @escaping @MainActor (EditorController, @escaping @Sendable (Double) -> Void) async throws -> Void) {
        if job != nil {
            showToast("ほかの処理が終わるまでお待ちください")
            return
        }
        job = JobState(title: title, progress: 0)
        jobTask = Task { [weak self] in
            guard let self = self else { return }
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor [weak self] in
                    self?.job?.progress = value
                }
            }
            do {
                try await work(self, report)
            } catch EngineError.cancelled {
                self.showToast("中止しました")
            } catch {
                self.alert = EditorAlert(title: title + "に失敗しました", message: error.localizedDescription)
                Diagnostics.shared.log("\(title) failed: \(error)")
            }
            self.job = nil
        }
    }

    func cancelJob() {
        jobTask?.cancel()
        job = nil
    }

    // MARK: 素材の下準備（プロキシ・波形・コマ）

    func prepareMedia() {
        for asset in project.media {
            prepare(asset)
        }
    }

    func prepare(_ asset: MediaAsset) {
        if asset.isVisual {
            ThumbnailStore.shared.load(asset) { [weak self] in
                self?.revision += 1
            }
        }
        if asset.hasAudio && AudioAnalyzer.cached(asset) == nil, let url = MediaStore.shared.url(for: asset) {
            let item: MediaAsset = asset
            Task.detached(priority: .utility) { [weak self] in
                _ = try? await AudioAnalyzer.features(for: item, url: url)
                await MainActor.run { self?.revision += 1 }
            }
        }
    }

    /// 重い素材（4K・HEVC 高フレームレート）はプロキシを作る。
    func makeProxyIfNeeded(_ asset: MediaAsset, auto: Bool) {
        if asset.proxyPath != nil || !asset.recommendsProxy(on: DevicePerformance.current) || !auto { return }
        let id: UUID = asset.id
        let item: MediaAsset = asset
        Task.detached(priority: .utility) { [weak self] in
            guard let path = try? await MediaJobs.makeProxy(for: item) else { return }
            await MainActor.run {
                self?.apply("プロキシ作成") { p in
                    if let index = p.media.firstIndex(where: { $0.id == id }) { p.media[index].proxyPath = path }
                }
                self?.showToast("軽いプロキシを作りました：\(item.name)")
            }
        }
    }
}

/// 合成の作り直しが必要かを判断するための「時間の並び」の要約。色や位置の変更だけなら作り直さない。
struct TimingKey: Equatable {
    struct ClipKey: Equatable {
        let id: UUID
        let kind: ClipKind
        let media: UUID?
        let start: Int64
        let duration: Int64
        let sourceStart: Int64
        let speed: SpeedSettings
        let transition: Int64
        let audio: AudioSettings
    }

    struct TrackKey: Equatable {
        let id: UUID
        let kind: TrackKind
        let hidden: Bool
        let muted: Bool
        let volume: Double
        let clips: [ClipKey]
    }

    let canvas: [Int]
    let tracks: [TrackKey]
    let media: [String]
    let scale: Double
    let proxies: Bool

    init(project: Project, scale: Double, proxies: Bool) {
        canvas = [project.canvas.width, project.canvas.height, Int(project.canvas.fps * 1000)]
        var trackKeys: [TrackKey] = []
        for track in project.tracks {
            var clipKeys: [ClipKey] = []
            for clip in track.clips {
                clipKeys.append(ClipKey(id: clip.id, kind: clip.kind, media: clip.mediaID, start: clip.start.ticks,
                                        duration: clip.duration.ticks, sourceStart: clip.sourceStart.ticks, speed: clip.speed,
                                        transition: clip.transitionIn?.duration.ticks ?? 0, audio: clip.audio))
            }
            trackKeys.append(TrackKey(id: track.id, kind: track.kind, hidden: track.isHidden, muted: track.isMuted,
                                      volume: track.volume, clips: clipKeys))
        }
        tracks = trackKeys
        var mediaKeys: [String] = []
        for asset in project.media {
            // 文字列の + と ?? を 1 つの式に並べると型チェックがとても重くなるので分ける
            var parts: [String] = [asset.id.uuidString]
            if let p = asset.proxyPath { parts.append(p) }
            if let p = asset.reversedPath { parts.append(p) }
            if let p = asset.interpolated?.path { parts.append(p) }
            mediaKeys.append(parts.joined(separator: "|"))
        }
        media = mediaKeys
        self.scale = scale
        self.proxies = proxies
    }
}
