import SwiftUI

/// 選択中のクリップが無いときの案内。
struct SelectClipHint: View {
    var body: some View {
        Text("タイムラインでクリップをタップして選んでください。")
            .font(.footnote)
            .foregroundStyle(Theme.subtext)
    }
}

/// キーフレームを打てるパラメーターの 1 行（Clip の Param を直接扱う）。
struct ClipParamRow: View {
    @ObservedObject var controller: EditorController
    let clip: Clip
    let label: String
    let path: WritableKeyPath<Clip, Param>
    let range: ClosedRange<Double>
    let defaultValue: Double
    var format: String = "%.2f"

    var body: some View {
        let param: Param = clip[keyPath: path]
        ParamRow(label: label, range: range, value: param.value(at: controller.localTime(of: clip)), format: format,
                 keyState: controller.keyState(param, clip: clip),
                 onChange: { controller.setParam(path, $0, name: label) },
                 onToggleKey: { controller.toggleKey(path, name: label) },
                 onReset: { controller.resetParam(path, to: defaultValue, name: label) })
    }
}

/// コマの間の作り方（Q99: コマの繰り返し・コマの合成・光学フロー）とモーションブラー。
/// スロー・速度カーブ・素材とプロジェクトのフレームレートの違いのどれにも効く。
struct FrameInterpolationRows: View {
    @ObservedObject var controller: EditorController
    let clip: Clip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(text: "コマの補間")
            ChipPicker(items: FrameInterpolation.allCases, selection: clip.speed.interpolation, label: { $0.label }, icon: { $0.iconID }) { mode in
                controller.setInterpolation(mode)
            }
            Text(clip.speed.interpolation.detail)
                .font(.caption2)
                .foregroundStyle(Theme.subtext)
            PanelTitle(text: "モーションブラー")
            ChipPicker(items: MotionBlur.choices, selection: FrameInterpolationRows.nearest(clip.speed.motionBlur),
                       label: { MotionBlur.label($0) }, icon: { $0 > 0.001 ? "speed.motionBlur" : "anim.none" }) { value in
                controller.setMotionBlur(value)
            }
            status
        }
    }

    static func nearest(_ value: Double) -> Double {
        var best: Double = MotionBlur.choices[0]
        for choice in MotionBlur.choices where abs(choice - value) < abs(best - value) {
            best = choice
        }
        return best
    }

    @ViewBuilder private var status: some View {
        let fps: Int = Int(controller.project.canvas.fps.rounded())
        let state: RetimeStatus = controller.retimeRevision >= 0 ? controller.retimeStatus(of: clip) : .notNeeded
        switch state {
        case .notNeeded:
            if clip.speed.makesFrames {
                note("今の速さとフレームレートでは、素材のコマをそのまま使います。", icon: "status.ok")
            }
        case .ready:
            note("\(fps)fps のコマを作成済みです。書き出しのフレームレートが違うときは書き出しの前に作ります。", icon: "status.done")
        case .missing:
            HStack(spacing: 8) {
                note("まだ作っていません（プレビューはコマの繰り返しです）", icon: "status.waiting")
                Spacer(minLength: 4)
                Button("コマを作る") { controller.makeRetimed(clip.id) }
                    .buttonStyle(.borderedProminent)
                    .font(.caption)
            }
        case .needsReverse:
            note("逆再生の準備が終わると作れます", icon: "status.reversePending")
        }
    }

    private func note(_ text: String, icon: String) -> some View {
        DVLabel(text, icon: icon)
            .font(.caption2)
            .foregroundStyle(Theme.subtext)
    }
}

/// 変形（Q35）と 3D（Q50）。
struct TransformPanel: View {
    @ObservedObject var controller: EditorController

    /// 3D のクリップは一回転まで、ほかは傾きだけ。
    static func tiltRange(_ clip: Clip) -> ClosedRange<Double> {
        let full: ClosedRange<Double> = -360...360
        let tilt: ClosedRange<Double> = -80...80
        return clip.kind == .object3D ? full : tilt
    }

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 6) {
                if clip.kind == .video || clip.kind == .image || clip.kind == .gif {
                    ChipPicker(items: FitMode.allCases, selection: clip.fitMode, label: { $0.label }, icon: { $0.iconID }) { mode in
                        controller.updateSelected("収め方") { $0.fitMode = mode }
                    }
                }
                ClipParamRow(controller: controller, clip: clip, label: "位置 X", path: \.transform.positionX, range: -1...1, defaultValue: 0)
                ClipParamRow(controller: controller, clip: clip, label: "位置 Y", path: \.transform.positionY, range: -1...1, defaultValue: 0)
                ClipParamRow(controller: controller, clip: clip, label: "大きさ", path: \.transform.scale, range: 0.05...5, defaultValue: 1)
                ClipParamRow(controller: controller, clip: clip, label: "回転", path: \.transform.rotation, range: -360...360, defaultValue: 0, format: "%.0f°")
                ClipParamRow(controller: controller, clip: clip, label: "不透明度", path: \.transform.opacity, range: 0...1, defaultValue: 1)
                PanelTitle(text: "3D")
                ClipParamRow(controller: controller, clip: clip, label: clip.kind == .object3D ? "X 軸の回転" : "縦の傾き", path: \.transform.rotationX,
                             range: TransformPanel.tiltRange(clip), defaultValue: 0, format: "%.0f°")
                ClipParamRow(controller: controller, clip: clip, label: clip.kind == .object3D ? "Y 軸の回転" : "横の傾き", path: \.transform.rotationY,
                             range: TransformPanel.tiltRange(clip), defaultValue: 0, format: "%.0f°")
                PanelTitle(text: "切り抜き・反転")
                CropRows(controller: controller, clip: clip)
                HStack {
                    Button {
                        controller.updateSelected("左右反転") { $0.transform.flipHorizontal.toggle() }
                    } label: { DVLabel("左右反転", icon: "edit.flipHorizontal") }
                    Button {
                        controller.updateSelected("上下反転") { $0.transform.flipVertical.toggle() }
                    } label: { DVLabel("上下反転", icon: "edit.flipVertical") }
                    Spacer()
                    Button("すべてリセット") {
                        controller.updateSelected("変形をリセット") { $0.transform = Transform() }
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        } else {
            SelectClipHint()
        }
    }
}

struct CropRows: View {
    @ObservedObject var controller: EditorController
    let clip: Clip

    var body: some View {
        VStack(spacing: 2) {
            row("左", clip.transform.cropLeft) { c, v in c.transform.cropLeft = v }
            row("右", clip.transform.cropRight) { c, v in c.transform.cropRight = v }
            row("上", clip.transform.cropTop) { c, v in c.transform.cropTop = v }
            row("下", clip.transform.cropBottom) { c, v in c.transform.cropBottom = v }
        }
    }

    private func row(_ label: String, _ value: Double, _ set: @escaping (inout Clip, Double) -> Void) -> some View {
        ParamRow(label: "切り抜き " + label, range: 0...0.45, value: value, onChange: { v in
            controller.updateSelected("切り抜き", coalesce: "crop-\(label)") { set(&$0, v) }
        })
    }
}

/// 速度（Q34）。
struct SpeedPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 10) {
                ParamRow(label: "速さ", range: -1...1, value: log10(clip.speed.rate), format: "%.2f",
                         onChange: { controller.setSpeed(pow(10, $0) * 1) })
                Text(String(format: "%.2f 倍 ・ 長さ %@", clip.speed.rate, clip.duration.shortLabel))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.subtext)
                ChipPicker(items: [0.1, 0.25, 0.5, 1.0, 1.5, 2.0, 4.0, 10.0], selection: clip.speed.hasCurve ? nil : clip.speed.rate,
                           label: { String(format: "%gx", $0) }) { rate in
                    controller.setSpeed(rate)
                }
                PanelTitle(text: "速度カーブ")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SpeedMap.presets, id: \.name) { preset in
                            IconChoiceButton(title: preset.name, icon: "speed." + preset.id, selected: clip.speed.curve == preset.points) {
                                controller.setSpeedCurve(preset.points)
                            }
                            .frame(width: 82)
                        }
                        if clip.speed.hasCurve {
                            IconChoiceButton(title: "カーブを解除", icon: "speed.curveOff") { controller.setSpeed(1) }
                                .frame(width: 82)
                        }
                    }
                }
                if clip.speed.hasCurve {
                    SpeedCurveGraph(points: clip.speed.curve)
                        .frame(height: 70)
                }
                Toggle("声の高さを保つ", isOn: Binding<Bool>(get: { clip.speed.preservePitch },
                                                     set: { v in controller.updateSelected("声の高さ") { $0.speed.preservePitch = v } }))
                    .font(.footnote)
                if clip.kind == .video {
                    FrameInterpolationRows(controller: controller, clip: clip)
                    HStack {
                        Button(clip.speed.reversed ? "逆再生を解除" : "逆再生") { controller.toggleReverse() }
                        Button("静止（2 秒）") { controller.freezeFrame() }
                    }
                    .buttonStyle(.bordered)
                    .font(.footnote)
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

struct SpeedCurveGraph: View {
    let points: [SpeedPoint]

    var body: some View {
        Canvas { context, size in
            let normalized: [SpeedPoint] = SpeedMap.normalized(points)
            var path = Path()
            for (i, p) in normalized.enumerated() {
                let x: CGFloat = CGFloat(p.position) * size.width
                let y: CGFloat = size.height * (1 - CGFloat(log10(p.rate) + 1) / 3)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(Theme.accent), lineWidth: 2)
            var base = Path()
            let oneY: CGFloat = size.height * (1 - 1.0 / 3.0)
            base.move(to: CGPoint(x: 0, y: oneY))
            base.addLine(to: CGPoint(x: size.width, y: oneY))
            context.stroke(base, with: .color(Theme.line), lineWidth: 1)
        }
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 音量（Q51, Q52）。
struct VolumePanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 8) {
                ClipParamRow(controller: controller, clip: clip, label: "音量", path: \.audio.volume, range: 0...2, defaultValue: 1)
                ParamRow(label: "フェードイン", range: 0...5, value: clip.audio.fadeIn.seconds, format: "%.1f秒", onChange: { v in
                    controller.updateSelected("フェードイン", coalesce: "fadein") { $0.audio.fadeIn = Time(seconds: v) }
                })
                ParamRow(label: "フェードアウト", range: 0...5, value: clip.audio.fadeOut.seconds, format: "%.1f秒", onChange: { v in
                    controller.updateSelected("フェードアウト", coalesce: "fadeout") { $0.audio.fadeOut = Time(seconds: v) }
                })
                Toggle("ミュート", isOn: Binding<Bool>(get: { clip.audio.isMuted },
                                                  set: { v in controller.updateSelected("ミュート") { $0.audio.isMuted = v } }))
                    .font(.footnote)
                if abs(clip.audio.gain - 1) > 0.001 {
                    Text(String(format: "自動そろえ：%+.1f dB", Num.dB(fromLinear: clip.audio.gain)))
                        .font(.caption)
                        .foregroundStyle(Theme.subtext)
                }
                HStack {
                    Button("音量を自動でそろえる") { controller.normalizeLoudness(all: false) }
                    Button("全クリップをそろえる") { controller.normalizeLoudness(all: true) }
                }
                .buttonStyle(.bordered)
                .font(.footnote)
                if let index = controller.selectedTrackIndex {
                    let track: Track = controller.project.tracks[index]
                    ParamRow(label: "トラック音量", range: 0...2, value: track.volume, onChange: { v in
                        let id: UUID = track.id
                        controller.apply("トラック音量", coalesce: "track-volume-\(id)") { p in
                            if let i = p.trackIndex(id) { p.tracks[i].volume = v }
                        }
                    })
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

/// 音声の加工（Q53）。
struct AudioFXPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            let processing: AudioProcessing = clip.audio.processing
            VStack(alignment: .leading, spacing: 10) {
                PanelTitle(text: "イコライザー")
                ChipPicker(items: EQPreset.allCases, selection: processing.eq, label: { $0.label }, icon: { $0.iconID }) { eq in
                    controller.updateSelected("イコライザー") { $0.audio.processing.eq = eq }
                }
                PanelTitle(text: "ボイスチェンジ")
                ChipPicker(items: VoicePreset.allCases, selection: processing.voice, label: { $0.label }, icon: { $0.iconID }) { voice in
                    controller.updateSelected("ボイスチェンジ") { $0.audio.processing.voice = voice }
                }
                ParamRow(label: "ノイズ除去", range: 0...1, value: processing.denoise, onChange: { v in
                    controller.updateSelected("ノイズ除去", coalesce: "denoise") { $0.audio.processing.denoise = v }
                })
                if processing.isActive {
                    HStack {
                        Text(processing.isRenderedUpToDate ? "適用済み" : "未適用（「適用」で端末内で処理します）")
                            .font(.caption)
                            .foregroundStyle(processing.isRenderedUpToDate ? Theme.subtext : Theme.accent)
                        Spacer()
                        Button("適用") { controller.renderAudioProcessing(clipID: clip.id) }
                            .buttonStyle(.borderedProminent)
                            .disabled(processing.isRenderedUpToDate)
                    }
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

/// トランジション（Q36）。
struct TransitionPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 10) {
                Text("選んだクリップと、その前のクリップのつなぎ目にかかります。")
                    .font(.caption)
                    .foregroundStyle(Theme.subtext)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    IconChoiceButton(title: "なし", icon: "anim.none", selected: clip.transitionIn == nil) {
                        controller.updateSelected("トランジション") { $0.transitionIn = nil }
                    }
                    ForEach(TransitionKind.allCases, id: \.self) { kind in
                        IconChoiceButton(title: kind.label, icon: kind.iconID, selected: clip.transitionIn?.kind == kind) {
                            let duration: Time = clip.transitionIn?.duration ?? Time(seconds: 0.5)
                            controller.updateSelected("トランジション") { $0.transitionIn = ClipTransition(kind: kind, duration: duration) }
                        }
                    }
                }
                if let transition = clip.transitionIn {
                    ParamRow(label: "長さ", range: 0.1...2, value: transition.duration.seconds, format: "%.2f秒", onChange: { v in
                        controller.updateSelected("トランジションの長さ", coalesce: "transition-duration") { $0.transitionIn?.duration = Time(seconds: v) }
                    })
                    Button("すべてのつなぎ目に同じものを使う") { controller.applyTransitionToAll(transition) }
                        .buttonStyle(.bordered)
                        .font(.footnote)
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

/// 出入りのアニメーション（重ねたクリップ・テキスト）。
struct AnimationPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 10) {
                PanelTitle(text: "登場")
                animationChips(current: clip.animationIn?.kind) { kind in
                    controller.updateSelected("登場アニメーション") { $0.animationIn = kind.map { ClipAnimation(kind: $0) } }
                }
                PanelTitle(text: "退場")
                animationChips(current: clip.animationOut?.kind) { kind in
                    controller.updateSelected("退場アニメーション") { $0.animationOut = kind.map { ClipAnimation(kind: $0) } }
                }
                if let text = clip.text {
                    PanelTitle(text: "テキストの動き")
                    ChipPicker(items: TextAnimation.allCases, selection: text.animation, label: { $0.label }) { animation in
                        controller.updateSelected("テキストの動き") { $0.text?.animation = animation }
                    }
                    ParamRow(label: "動きの長さ", range: 0.1...3, value: text.animationDuration, format: "%.1f秒", onChange: { v in
                        controller.updateSelected("テキストの動きの長さ", coalesce: "text-anim") { $0.text?.animationDuration = v }
                    })
                }
            }
        } else {
            SelectClipHint()
        }
    }

    private func animationChips(current: AnimationKind?, _ select: @escaping (AnimationKind?) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                IconChoiceButton(title: "なし", icon: "anim.none", selected: current == nil) { select(nil) }
                    .frame(width: 64)
                ForEach(AnimationKind.allCases, id: \.self) { kind in
                    IconChoiceButton(title: kind.label, icon: kind.iconID, selected: current == kind) { select(kind) }
                        .frame(width: 64)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// 不透明度・ブレンド・背景除去（Q43, Q45）。
struct BlendPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 10) {
                ClipParamRow(controller: controller, clip: clip, label: "不透明度", path: \.transform.opacity, range: 0...1, defaultValue: 1)
                PanelTitle(text: "ブレンド")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(LayerBlend.allCases, id: \.self) { mode in
                        IconChoiceButton(title: mode.label, icon: mode.iconID, selected: clip.blend == mode) {
                            controller.updateSelected("ブレンド") { $0.blend = mode }
                        }
                    }
                }
                if clip.kind == .video || clip.kind == .image {
                    Toggle("背景を消す（人物を切り抜く・端末内 AI）", isOn: Binding<Bool>(get: { clip.removeBackground },
                                                                         set: { v in controller.updateSelected("背景除去") { $0.removeBackground = v } }))
                        .font(.footnote)
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

/// マスク（Q43）とモザイク枠の範囲。
struct MaskPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        IconChoiceButton(title: "なし", icon: "mask.none", selected: clip.mask == nil) {
                            controller.updateSelected("マスク") { $0.mask = nil }
                        }
                        .frame(width: 64)
                        ForEach(MaskShape.allCases, id: \.self) { shape in
                            IconChoiceButton(title: shape.label, icon: shape.iconID, selected: clip.mask?.shape == shape) {
                                controller.updateSelected("マスク") { c in
                                    if c.mask == nil { c.mask = MaskSettings(shape: shape) } else { c.mask?.shape = shape }
                                }
                            }
                            .frame(width: 64)
                        }
                    }
                    .padding(.vertical, 2)
                }
                if clip.mask != nil {
                    ClipParamRow(controller: controller, clip: clip, label: "中心 X", path: \.maskCenterX, range: 0...1, defaultValue: 0.5)
                    ClipParamRow(controller: controller, clip: clip, label: "中心 Y", path: \.maskCenterY, range: 0...1, defaultValue: 0.5)
                    ClipParamRow(controller: controller, clip: clip, label: "幅", path: \.maskWidth, range: 0.02...1.5, defaultValue: 0.5)
                    ClipParamRow(controller: controller, clip: clip, label: "高さ", path: \.maskHeight, range: 0.02...1.5, defaultValue: 0.5)
                    ClipParamRow(controller: controller, clip: clip, label: "回転", path: \.maskRotation, range: -180...180, defaultValue: 0, format: "%.0f°")
                    ClipParamRow(controller: controller, clip: clip, label: "ぼかし", path: \.maskFeather, range: 0...0.3, defaultValue: 0.02)
                    Toggle("反転", isOn: Binding<Bool>(get: { clip.mask?.invert ?? false },
                                                    set: { v in controller.updateSelected("マスクの反転") { $0.mask?.invert = v } }))
                        .font(.footnote)
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

/// マスクの値をキーパスで扱えるようにする（マスクが無いときは既定値）。
extension Clip {
    var maskCenterX: Param {
        get { return mask?.centerX ?? Param(0.5) }
        set { mask?.centerX = newValue }
    }

    var maskCenterY: Param {
        get { return mask?.centerY ?? Param(0.5) }
        set { mask?.centerY = newValue }
    }

    var maskWidth: Param {
        get { return mask?.width ?? Param(0.5) }
        set { mask?.width = newValue }
    }

    var maskHeight: Param {
        get { return mask?.height ?? Param(0.5) }
        set { mask?.height = newValue }
    }

    var maskRotation: Param {
        get { return mask?.rotation ?? Param(0) }
        set { mask?.rotation = newValue }
    }

    var maskFeather: Param {
        get { return mask?.feather ?? Param(0.02) }
        set { mask?.feather = newValue }
    }
}

/// クロマキー（Q43）。
struct ChromaPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("クロマキーを使う", isOn: Binding<Bool>(get: { clip.chromaKey != nil },
                                                        set: { v in controller.updateSelected("クロマキー") { $0.chromaKey = v ? ChromaKeySettings() : nil } }))
                    .font(.footnote)
                if let key = clip.chromaKey {
                    HStack {
                        Button("グリーン") { controller.updateSelected("キーの色") { $0.chromaKey?.color = .green } }
                        Button("ブルー") { controller.updateSelected("キーの色") { $0.chromaKey?.color = RGBA(0, 0.3, 1) } }
                        ColorPicker("色を選ぶ", selection: Binding<Color>(get: { key.color.color },
                                                                       set: { c in controller.updateSelected("キーの色", coalesce: "key-color") { $0.chromaKey?.color = RGBA(c) } }),
                                    supportsOpacity: false)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    ParamRow(label: "許容範囲", range: 0.01...0.4, value: key.tolerance, onChange: { v in
                        controller.updateSelected("許容範囲", coalesce: "key-tolerance") { $0.chromaKey?.tolerance = v }
                    })
                    ParamRow(label: "なめらかさ", range: 0.001...0.3, value: key.softness, onChange: { v in
                        controller.updateSelected("なめらかさ", coalesce: "key-softness") { $0.chromaKey?.softness = v }
                    })
                    ParamRow(label: "色かぶり除去", range: 0...1, value: key.spill, onChange: { v in
                        controller.updateSelected("色かぶり除去", coalesce: "key-spill") { $0.chromaKey?.spill = v }
                    })
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

/// キーフレームの一覧と補間（Q44）。
struct KeyframesPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            let entries: [(String, WritableKeyPath<Clip, Param>)] = KeyframesPanel.entries
            VStack(alignment: .leading, spacing: 8) {
                Text("◆ を押すと、今の再生位置にキーフレームを打てます。キーの間は下の補間でつながります。")
                    .font(.caption)
                    .foregroundStyle(Theme.subtext)
                ForEach(entries.indices, id: \.self) { i in
                    let entry: (String, WritableKeyPath<Clip, Param>) = entries[i]
                    KeyframeRow(controller: controller, clip: clip, name: entry.0, path: entry.1)
                }
            }
        } else {
            SelectClipHint()
        }
    }

    static let entries: [(String, WritableKeyPath<Clip, Param>)] = [
        ("位置 X", \Clip.transform.positionX), ("位置 Y", \Clip.transform.positionY), ("大きさ", \Clip.transform.scale),
        ("回転", \Clip.transform.rotation), ("不透明度", \Clip.transform.opacity), ("縦の傾き", \Clip.transform.rotationX),
        ("横の傾き", \Clip.transform.rotationY), ("音量", \Clip.audio.volume)
    ]
}

struct KeyframeRow: View {
    @ObservedObject var controller: EditorController
    let clip: Clip
    let name: String
    let path: WritableKeyPath<Clip, Param>

    var body: some View {
        let param: Param = clip[keyPath: path]
        let local: Time = controller.localTime(of: clip)
        let index: Int? = param.keyIndex(near: local, tolerance: controller.keyTolerance)
        HStack {
            Text(name).font(.footnote).frame(width: 80, alignment: .leading)
            Text("\(param.keys.count) 個").font(.caption).foregroundStyle(Theme.subtext)
            Spacer()
            if let i = index {
                Menu(param.keys[i].easing.label) {
                    ForEach(Easing.allCases, id: \.self) { easing in
                        Button(easing.label) {
                            controller.updateSelected("補間") { c in
                                c[keyPath: path].setEasing(easing, at: local, tolerance: controller.keyTolerance)
                            }
                        }
                    }
                }
                .font(.caption)
            }
            Button {
                controller.toggleKey(path, name: name)
            } label: {
                DVImage(index == nil ? "param.key" : "param.key.on")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            if param.isAnimated {
                Button {
                    controller.updateSelected("キーフレームを消す") { c in c[keyPath: path].removeAllKeys() }
                } label: {
                    DVImage("keyframe.delete")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.subtext)
            }
        }
    }
}
