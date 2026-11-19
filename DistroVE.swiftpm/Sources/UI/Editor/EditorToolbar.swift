import SwiftUI

/// ツールバー（Q66）。何も選んでいないときは追加の道具、クリップを選ぶとそのクリップの道具を出す。
struct EditorToolbar: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let clip = controller.selectedClip {
                    clipTools(clip)
                } else if controller.selectedClipIDs.count > 1 {
                    multiTools
                } else if controller.selectedCueID != nil {
                    cueTools
                } else {
                    rootTools
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Theme.raised)
    }

    private func open(_ panel: EditorPanel) {
        controller.panel = controller.panel == panel ? nil : panel
    }

    private func tool(_ title: String, _ symbol: String, panel: EditorPanel? = nil, enabled: Bool = true, action: (() -> Void)? = nil) -> some View {
        let active: Bool = panel != nil && controller.panel == panel
        return ToolButton(title: title, symbol: symbol, isActive: active, isEnabled: enabled) {
            if let a = action {
                a()
            } else if let p = panel {
                open(p)
            }
        }
    }

    // MARK: 何も選んでいないとき

    @ViewBuilder
    private var rootTools: some View {
        tool("素材", "plus.rectangle.on.rectangle", panel: .media)
        tool("オーディオ", "music.note", panel: .audioLibrary)
        tool("テキスト", "textformat", panel: .text)
        tool("ステッカー", "face.smiling", panel: .stickers)
        tool("字幕", "captions.bubble", panel: .subtitles)
        tool("AI", "wand.and.stars", panel: .ai)
        tool("分割", "scissors", action: { controller.splitAtPlayhead() })
        tool("マーカー", "bookmark", action: { controller.toggleMarker() })
        tool("並べ替え", "list.bullet", panel: .reorder)
        tool("手書き", "pencil.tip", panel: .drawing)
        tool("画面", "aspectratio", panel: .canvas)
        tool("フィルター", "camera.filters", action: { controller.addAdjustmentLayer() })
    }

    // MARK: クリップを選んだとき

    @ViewBuilder
    private func clipTools(_ clip: Clip) -> some View {
        tool("分割", "scissors", action: { controller.splitAtPlayhead() })
        tool("削除", "trash", action: { controller.deleteSelection(ripple: false) })
        tool("リップル削除", "arrow.left.to.line", action: { controller.deleteSelection(ripple: true) })
        tool("複製", "plus.square.on.square", action: { controller.duplicateSelection() })
        switch clip.kind {
        case .video:
            visualTools(clip)
            tool("速度", "speedometer", panel: .speed)
            tool("音量", "speaker.wave.2", panel: .volume)
            tool("音声加工", "waveform", panel: .audioFX)
            tool(clip.speed.reversed ? "逆再生 解除" : "逆再生", "backward", action: { controller.toggleReverse() })
            tool("静止", "pause.rectangle", action: { controller.freezeFrame() })
            tool("トランジション", "rectangle.2.swap", panel: .transition, enabled: isOnMain(clip))
        case .image, .gif, .solid:
            visualTools(clip)
            tool("トランジション", "rectangle.2.swap", panel: .transition, enabled: isOnMain(clip))
        case .text, .sticker:
            tool("編集", "character.cursor.ibeam", panel: .text)
            tool("変形", "arrow.up.left.and.arrow.down.right", panel: .transform)
            tool("アニメ", "sparkles", panel: .animation)
            tool("エフェクト", "wand.and.rays", panel: .effects)
            tool("ブレンド", "square.stack.3d.down.right", panel: .blend)
        case .shape:
            tool("変形", "arrow.up.left.and.arrow.down.right", panel: .transform)
            tool("アニメ", "sparkles", panel: .animation)
            tool("ブレンド", "square.stack.3d.down.right", panel: .blend)
        case .audio:
            tool("音量", "speaker.wave.2", panel: .volume)
            tool("音声加工", "waveform", panel: .audioFX)
            tool("速度", "speedometer", panel: .speed)
            tool("ビート検出", "metronome", action: { controller.detectBeats(clipID: clip.id) })
        case .adjustment:
            tool("調整", "slider.horizontal.3", panel: .adjust)
            tool("フィルター", "camera.filters", panel: .filters)
            tool("エフェクト", "wand.and.rays", panel: .effects)
            tool("範囲", "circle.dashed", panel: .mask)
        }
        tool("キーフレーム", "diamond", panel: .keyframes)
    }

    @ViewBuilder
    private func visualTools(_ clip: Clip) -> some View {
        tool("変形", "arrow.up.left.and.arrow.down.right", panel: .transform)
        tool("調整", "slider.horizontal.3", panel: .adjust)
        tool("フィルター", "camera.filters", panel: .filters)
        tool("エフェクト", "wand.and.rays", panel: .effects)
        tool("アニメ", "sparkles", panel: .animation)
        tool("マスク", "circle.dashed", panel: .mask)
        tool("クロマキー", "person.crop.square.filled.and.at.rectangle", panel: .chroma)
        tool("ブレンド", "square.stack.3d.down.right", panel: .blend)
    }

    private func isOnMain(_ clip: Clip) -> Bool {
        guard let loc = controller.project.locate(clip.id) else { return false }
        return loc.track == controller.project.mainTrackIndex && loc.clip > 0
    }

    // MARK: 複数選択・字幕

    @ViewBuilder
    private var multiTools: some View {
        tool("分割", "scissors", action: { controller.splitAtPlayhead() })
        tool("削除", "trash", action: { controller.deleteSelection(ripple: false) })
        tool("リップル削除", "arrow.left.to.line", action: { controller.deleteSelection(ripple: true) })
        tool("選択解除", "xmark", action: { controller.select(nil) })
    }

    @ViewBuilder
    private var cueTools: some View {
        tool("字幕を編集", "captions.bubble", panel: .subtitles)
        tool("削除", "trash", action: { controller.deleteSelection(ripple: false) })
        tool("選択解除", "xmark", action: { controller.selectCue(nil) })
    }
}
