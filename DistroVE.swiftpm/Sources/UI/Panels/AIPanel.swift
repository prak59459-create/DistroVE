import SwiftUI

/// AI ツール（Q45）。すべて端末内で処理する。サーバーを使うのは、利用者が許可した文字起こしだけ。
struct AIPanel: View {
    @ObservedObject var controller: EditorController
    @EnvironmentObject private var settings: AppSettings
    @State private var beatsPerCut: Int = 2
    @State private var silenceDB: Double = -40
    @State private var minSilence: Double = 0.6
    @State private var highlightSeconds: Double = 30
    @State private var shortSeconds: Double = 60
    @State private var askServer: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tool("自動字幕", "ai.captions", "話している言葉を文字にして字幕トラックを作ります（日本語）。") {
                Button("字幕を作る") { startCaptions() }
            }
            tool("背景除去", "ai.removeBackground", "選んだクリップの人物だけを残します。") {
                Button(controller.selectedClip?.removeBackground == true ? "解除" : "背景を消す") {
                    guard let clip = controller.selectedClip else { controller.showToast("クリップを選んでください"); return }
                    let on: Bool = !clip.removeBackground
                    controller.updateSelected("背景除去") { $0.removeBackground = on }
                }
            }
            tool("無音カット", "ai.silenceCut", "声や音の無いところを自動で切って詰めます。") {
                VStack(alignment: .leading) {
                    ParamRow(label: "無音の基準", range: -60 ... -20, value: silenceDB, format: "%.0f dB", onChange: { silenceDB = $0 })
                    ParamRow(label: "最短の長さ", range: 0.2...3, value: minSilence, format: "%.1f秒", onChange: { minSilence = $0 })
                    Button("無音を切る") { controller.cutSilence(thresholdDB: silenceDB, minSilence: minSilence) }
                }
            }
            tool("BGM に合わせて自動編集", "ai.beatEdit", "BGM のビートで、メイントラックの素材を切り替えます。") {
                VStack(alignment: .leading) {
                    Stepper("\(beatsPerCut) 拍ごとに切り替え", value: $beatsPerCut, in: 1...16)
                        .font(.footnote)
                    Button("自動編集する") { controller.autoEditToBeats(beatsPerCut: beatsPerCut) }
                }
            }
            tool("ハイライト抽出", "ai.highlights", "盛り上がっているところだけを集めます（音と映像の動きで判断）。") {
                VStack(alignment: .leading) {
                    ParamRow(label: "長さ", range: 10...180, value: highlightSeconds, format: "%.0f秒", onChange: { highlightSeconds = $0 })
                    Button("ハイライトを作る") { controller.makeHighlights(targetSeconds: highlightSeconds) }
                }
            }
            tool("ショート動画に変換", "ai.shorts", "9:16 にして、被写体が中央に来るように寄せ、長さを切りつめます。") {
                VStack(alignment: .leading) {
                    ParamRow(label: "最大の長さ", range: 15...180, value: shortSeconds, format: "%.0f秒", onChange: { shortSeconds = $0 })
                    Button("ショートにする") { controller.convertToShort(maxSeconds: shortSeconds) }
                }
            }
            tool("手ぶれ補正", "ai.stabilize", "選んだ動画の揺れを解析して打ち消します。") {
                Button(controller.selectedClip?.stabilization == nil ? "補正する" : "解除") { controller.toggleStabilization() }
            }
            tool("ビート検出", "ai.beatDetect", "選んだ音声（または BGM）からビートマーカーを作ります。") {
                Button("ビートを探す") { controller.detectBeats(clipID: controller.selectedClip?.id) }
            }
            tool("音量の自動そろえ", "ai.loudness", "すべてのクリップの音量を -14 LUFS 前後にそろえます。") {
                Button("そろえる") { controller.normalizeLoudness(all: true) }
            }
        }
        .alert("サーバーでの文字起こし", isPresented: $askServer) {
            Button("許可して続ける") {
                settings.allowServerSpeech = true
                controller.autoCaptions(allowServer: true)
            }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("この端末は日本語の端末内文字起こしに対応していません。音声だけを Apple のサーバーに送って文字にしてよいですか？ 動画そのものは送りません。")
        }
    }

    private func startCaptions() {
        if Transcriber.supportsOnDevice(Locale(identifier: "ja-JP")) || settings.allowServerSpeech {
            controller.autoCaptions(allowServer: settings.allowServerSpeech)
        } else {
            askServer = true
        }
    }

    private func tool<Content: View>(_ title: String, _ symbol: String, _ detail: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DVLabel(title, icon: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.subtext)
            content()
                .buttonStyle(.bordered)
                .font(.footnote)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// AI・解析の操作。
extension EditorController {
    /// 対象のクリップ（選択中、なければメイントラックの動画すべて）。
    private func targetClips(requireAudio: Bool) -> [Clip] {
        if let clip = selectedClip { return [clip] }
        var result: [Clip] = []
        for track in project.tracks where track.kind != .subtitle {
            for clip in track.clips where clip.kind == .video || clip.kind == .audio {
                if requireAudio, project.asset(clip.mediaID)?.hasAudio != true { continue }
                result.append(clip)
            }
        }
        return result
    }

    func autoCaptions(allowServer: Bool) {
        let clips: [Clip] = targetClips(requireAudio: true).filter { $0.kind == .video || $0.kind == .audio }
        if clips.isEmpty {
            showToast("音声のあるクリップがありません")
            return
        }
        let snapshot: Project = project
        runJob("自動字幕") { controller, progress in
            guard await Transcriber.authorize() else {
                throw EngineError.notAuthorized("音声認識の許可が必要です（設定 App から許可できます）")
            }
            var cues: [SubtitleCue] = []
            for (i, clip) in clips.enumerated() {
                guard let asset = snapshot.asset(clip.mediaID), let url = MediaStore.shared.url(for: asset) else { continue }
                let range = TimeRange(start: clip.sourceStart, duration: clip.sourceDuration)
                let words: [AutoEdit.Word] = try await Transcriber.transcribe(url: url, range: range, locale: Locale(identifier: "ja-JP"),
                                                                              allowServer: allowServer, progress: { p in
                    progress((Double(i) + p) / Double(clips.count))
                })
                // 素材の時刻からタイムラインの時刻へ（速度変更も考える）
                let rate: Double = SpeedMap(settings: clip.speed).meanRate
                var mapped: [AutoEdit.Word] = []
                for w in words {
                    mapped.append(AutoEdit.Word(text: w.text, start: w.start / rate, duration: w.duration / rate))
                }
                cues.append(contentsOf: AutoEdit.buildCues(words: mapped, offset: clip.start))
            }
            if cues.isEmpty {
                controller.showToast("話し声が見つかりませんでした")
                return
            }
            controller.apply("自動字幕") { p in p.setCues(cues, replace: false) }
            controller.showToast("\(cues.count) 件の字幕を作りました")
            controller.panel = .subtitles
        }
    }

    func cutSilence(thresholdDB: Double, minSilence: Double) {
        let clips: [Clip] = targetClips(requireAudio: true).filter { $0.kind == .video || $0.kind == .audio }
        if clips.isEmpty {
            showToast("音声のあるクリップを選んでください")
            return
        }
        let snapshot: Project = project
        runJob("無音カット") { controller, progress in
            var plans: [(UUID, [ClosedRange<Double>])] = []
            for (i, clip) in clips.enumerated() {
                guard let asset = snapshot.asset(clip.mediaID), let url = MediaStore.shared.url(for: asset) else { continue }
                let features: AudioFeatures = try await AudioAnalyzer.features(for: asset, url: url)
                let options = SilenceDetector.Options(thresholdDB: thresholdDB, minSilence: minSilence, padding: 0.12)
                plans.append((clip.id, SilenceDetector.detect(features, options: options)))
                progress(Double(i + 1) / Double(clips.count))
            }
            var removed: Int = 0
            controller.apply("無音カット") { p in
                for plan in plans.reversed() {
                    removed += AutoEdit.cutSilences(project: &p, clipID: plan.0, silences: plan.1)
                }
            }
            controller.showToast(removed == 0 ? "切り取る無音はありませんでした" : "\(removed) か所の無音を切りました")
        }
    }

    /// BGM（音声トラックの最初のクリップ）のビートで、メイントラックの素材を切り替える。
    func autoEditToBeats(beatsPerCut: Int) {
        guard let audioIndex = project.trackIndices(of: .audio).first(where: { !project.tracks[$0].clips.isEmpty }),
              let bgm = project.tracks[audioIndex].clips.first, let asset = project.asset(bgm.mediaID) else {
            showToast("先に BGM を音声トラックに置いてください")
            return
        }
        guard let main = project.mainTrackIndex, !project.tracks[main].clips.isEmpty else {
            showToast("メイントラックに素材を置いてください")
            return
        }
        var sources: [AutoEdit.Source] = []
        for clip in project.tracks[main].clips where clip.kind == .video || clip.kind == .image || clip.kind == .gif {
            guard let media = project.asset(clip.mediaID) else { continue }
            let still: Bool = !media.hasFiniteDuration
            sources.append(AutoEdit.Source(mediaID: media.id, name: clip.name, sourceStart: clip.sourceStart,
                                           sourceDuration: still ? Time(seconds: 600) : clip.sourceDuration, isStill: still, template: clip))
        }
        let bgmStart: Time = bgm.start
        let bgmSourceStart: Time = bgm.sourceStart
        let bgmEnd: Time = bgm.end
        runJob("ビートの解析") { controller, _ in
            guard let url = MediaStore.shared.url(for: asset) else { throw EngineError.missingMedia(asset.name) }
            let features: AudioFeatures = try await AudioAnalyzer.features(for: asset, url: url)
            guard let analysis = BeatDetector.analyze(features) else { throw EngineError.unreadable("ビートが見つかりません") }
            var beats: [Time] = []
            for b in analysis.beats {
                let t: Time = bgmStart + Time(seconds: b) - bgmSourceStart
                if t >= .zero && t <= bgmEnd { beats.append(t) }
            }
            controller.apply("BGM に合わせて自動編集") { p in
                p.setBeatMarkers(beats)
                _ = AutoEdit.beatSync(project: &p, sources: sources, beats: beats, beatsPerCut: beatsPerCut, maxDuration: bgmEnd)
            }
            controller.showToast(String(format: "%.0f BPM で切り替えました", analysis.bpm))
        }
    }

    func detectBeats(clipID: UUID?) {
        var target: Clip?
        if let id = clipID, let clip = project.clip(id), clip.kind == .audio || clip.kind == .video {
            target = clip
        } else if let audioIndex = project.trackIndices(of: .audio).first(where: { !project.tracks[$0].clips.isEmpty }) {
            target = project.tracks[audioIndex].clips.first
        }
        guard let clip = target, let asset = project.asset(clip.mediaID), asset.hasAudio else {
            showToast("音声のクリップを選んでください")
            return
        }
        runJob("ビート検出") { controller, _ in
            guard let url = MediaStore.shared.url(for: asset) else { throw EngineError.missingMedia(asset.name) }
            let features: AudioFeatures = try await AudioAnalyzer.features(for: asset, url: url)
            guard let analysis = BeatDetector.analyze(features) else { throw EngineError.unreadable("ビートが見つかりません") }
            let rate: Double = SpeedMap(settings: clip.speed).meanRate
            var beats: [Time] = []
            for b in analysis.beats {
                let local: Double = (b - clip.sourceStart.seconds) / rate
                if local < 0 || local > clip.duration.seconds { continue }
                beats.append(clip.start + Time(seconds: local))
            }
            controller.apply("ビート検出") { p in p.setBeatMarkers(beats) }
            controller.showToast(String(format: "%.0f BPM・%d 拍を見つけました", analysis.bpm, beats.count))
        }
    }

    func makeHighlights(targetSeconds: Double) {
        guard let clip = selectedClip ?? project.mainTrackIndex.flatMap({ project.tracks[$0].clips.max(by: { $0.duration < $1.duration }) }),
              clip.kind == .video, let asset = project.asset(clip.mediaID) else {
            showToast("動画のクリップを選んでください")
            return
        }
        runJob("ハイライト抽出") { controller, progress in
            guard let url = MediaStore.shared.url(for: asset) else { throw EngineError.missingMedia(asset.name) }
            let motion: [Double] = (try? await VisionTools.motionScores(url: url, duration: asset.duration, progress: { p in progress(p * 0.7) })) ?? []
            var segments: [HighlightDetector.Segment] = []
            if asset.hasAudio {
                let features: AudioFeatures = try await AudioAnalyzer.features(for: asset, url: url)
                segments = HighlightDetector.scores(features, window: 3, motion: motion)
            } else {
                for (i, m) in motion.enumerated() {
                    segments.append(HighlightDetector.Segment(start: Double(i), duration: 3, score: m))
                }
            }
            let picked: [HighlightDetector.Segment] = HighlightDetector.pick(segments, target: targetSeconds)
            let source = AutoEdit.Source(mediaID: asset.id, name: asset.name, sourceStart: .zero, sourceDuration: asset.duration, isStill: false, template: clip)
            controller.apply("ハイライト抽出") { p in
                _ = AutoEdit.highlightReel(project: &p, source: source, segments: picked)
            }
            controller.showToast("\(picked.count) か所の盛り上がりを集めました")
        }
    }

    func convertToShort(maxSeconds: Double) {
        let snapshot: Project = project
        runJob("ショート動画に変換") { controller, progress in
            var subjects: [UUID: Double] = [:]
            let videos: [MediaAsset] = snapshot.media.filter { $0.kind == .video }
            for (i, asset) in videos.enumerated() {
                if let url = MediaStore.shared.url(for: asset),
                   let x = await VisionTools.subjectCenterX(url: url, at: Time(seconds: asset.duration.seconds / 2)) {
                    subjects[asset.id] = x
                }
                progress(Double(i + 1) / Double(max(1, videos.count)))
            }
            controller.apply("ショート動画に変換") { p in
                AutoEdit.convertToShort(project: &p, maxDuration: Time(seconds: maxSeconds), subjectX: subjects)
            }
            controller.showToast("9:16 のショートにしました")
        }
    }

    func toggleStabilization() {
        guard let clip = selectedClip, clip.kind == .video, let asset = project.asset(clip.mediaID) else {
            showToast("動画のクリップを選んでください")
            return
        }
        if clip.stabilization != nil {
            updateSelected("手ぶれ補正を解除") { $0.stabilization = nil }
            return
        }
        let id: UUID = clip.id
        runJob("手ぶれ補正の解析") { controller, progress in
            guard let url = MediaStore.shared.url(for: asset) else { throw EngineError.missingMedia(asset.name) }
            let data: StabilizationData = try await VisionTools.stabilization(url: url, sourceStart: .zero, sourceDuration: asset.duration, progress: progress)
            controller.apply("手ぶれ補正") { p in p.updateClip(id) { $0.stabilization = data } }
            controller.showToast("手ぶれを補正しました")
        }
    }

    func normalizeLoudness(all: Bool) {
        let clips: [Clip] = all ? targetClipsAll() : (selectedClip.map { [$0] } ?? [])
        if clips.isEmpty {
            showToast("音声のあるクリップがありません")
            return
        }
        let snapshot: Project = project
        runJob("音量の自動そろえ") { controller, progress in
            var gains: [UUID: Double] = [:]
            for (i, clip) in clips.enumerated() {
                guard let asset = snapshot.asset(clip.mediaID), asset.hasAudio, let url = MediaStore.shared.url(for: asset) else { continue }
                let features: AudioFeatures = try await AudioAnalyzer.features(for: asset, url: url)
                gains[clip.id] = Loudness.gain(for: features, targetLUFS: -14)
                progress(Double(i + 1) / Double(clips.count))
            }
            controller.apply("音量の自動そろえ") { p in
                for (id, gain) in gains {
                    p.updateClip(id) { $0.audio.gain = gain }
                }
            }
            controller.showToast("\(gains.count) 本の音量をそろえました")
        }
    }

    private func targetClipsAll() -> [Clip] {
        var result: [Clip] = []
        for track in project.tracks {
            for clip in track.clips where clip.kind == .video || clip.kind == .audio {
                result.append(clip)
            }
        }
        return result
    }

    func renderAudioProcessing(clipID: UUID) {
        guard let clip = project.clip(clipID), let asset = project.asset(clip.mediaID), let url = MediaStore.shared.url(for: asset) else { return }
        let processing: AudioProcessing = clip.audio.processing
        runJob("音声の加工") { controller, progress in
            let path: String = try await AudioProcessor.render(source: url, processing: processing, progress: progress)
            controller.apply("音声の加工を適用") { p in
                p.updateClip(clipID) { c in
                    c.audio.processing.renderedPath = path
                    c.audio.processing.renderedSignature = processing.signature
                }
            }
            controller.showToast("音声の加工を適用しました")
        }
    }

    func applyTransitionToAll(_ transition: ClipTransition) {
        apply("トランジションをすべてに") { p in
            guard let main = p.mainTrackIndex else { return }
            for i in p.tracks[main].clips.indices where i > 0 {
                p.tracks[main].clips[i].transitionIn = transition
            }
        }
    }
}
