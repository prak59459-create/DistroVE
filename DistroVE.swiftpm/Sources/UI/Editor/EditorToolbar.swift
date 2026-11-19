import SwiftUI

/// ツールバー（Q66）。何も選んでいないときは追加の道具、クリップを選ぶとそのクリップの道具を出す。
/// 道具の並びと表示は設定で変えられ（Q70）、編集の経験（Q15）に合わせて出す道具を変える。
struct EditorToolbar: View {
    @ObservedObject var controller: EditorController
    @EnvironmentObject var settings: AppSettings

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

    private var advanced: Bool { return settings.editorLevel >= .standard }
    private var pro: Bool { return settings.editorLevel == .pro }

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

    private var rootTools: some View {
        ForEach(settings.visibleRootTools) { item in
            rootTool(item)
        }
    }

    private func rootTool(_ item: RootTool) -> some View {
        let panel: EditorPanel? = EditorToolbar.panel(for: item)
        let action: (() -> Void)? = panel == nil ? { self.rootAction(item) } : nil
        return tool(item.title, item.symbol, panel: panel, action: action)
    }

    static func panel(for item: RootTool) -> EditorPanel? {
        switch item {
        case .media: return .media
        case .audio: return .audioLibrary
        case .text: return .text
        case .stickers: return .stickers
        case .object3D: return .object3D
        case .subtitles: return .subtitles
        case .ai: return .ai
        case .reorder: return .reorder
        case .drawing: return .drawing
        case .canvas: return .canvas
        case .split, .filter, .marker: return nil
        }
    }

    private func rootAction(_ item: RootTool) {
        switch item {
        case .split: controller.splitAtPlayhead()
        case .marker: controller.toggleMarker()
        case .filter: controller.addAdjustmentLayer()
        default: break
        }
    }

    // MARK: クリップを選んだとき

    @ViewBuilder
    private func clipTools(_ clip: Clip) -> some View {
        if pro {
            tool("キーフレーム", "diamond", panel: .keyframes)
        }
        tool("分割", "scissors", action: { controller.splitAtPlayhead() })
        tool("削除", "trash", action: { controller.deleteSelection(ripple: false) })
        if advanced {
            tool("リップル削除", "arrow.left.to.line", action: { controller.deleteSelection(ripple: true) })
        }
        tool("複製", "plus.square.on.square", action: { controller.duplicateSelection() })
        kindTools(clip)
        if advanced && !pro {
            tool("キーフレーム", "diamond", panel: .keyframes)
        }
    }

    @ViewBuilder
    private func kindTools(_ clip: Clip) -> some View {
        switch clip.kind {
        case .video:
            visualTools(clip)
            tool("速度", "speedometer", panel: .speed)
            tool("音量", "speaker.wave.2", panel: .volume)
            if advanced { tool("音声加工", "waveform", panel: .audioFX) }
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
            if advanced {
                tool("エフェクト", "wand.and.rays", panel: .effects)
                tool("ブレンド", "square.stack.3d.down.right", panel: .blend)
            }
        case .shape:
            tool("変形", "arrow.up.left.and.arrow.down.right", panel: .transform)
            tool("アニメ", "sparkles", panel: .animation)
            if advanced { tool("ブレンド", "square.stack.3d.down.right", panel: .blend) }
        case .object3D:
            tool("3D", "cube", panel: .object3D)
            tool("変形", "arrow.up.left.and.arrow.down.right", panel: .transform)
            tool("アニメ", "sparkles", panel: .animation)
            if advanced {
                tool("エフェクト", "wand.and.rays", panel: .effects)
                tool("ブレンド", "square.stack.3d.down.right", panel: .blend)
            }
        case .audio:
            tool("音量", "speaker.wave.2", panel: .volume)
            tool("速度", "speedometer", panel: .speed)
            if advanced {
                tool("音声加工", "waveform", panel: .audioFX)
                tool("ビート検出", "metronome", action: { controller.detectBeats(clipID: clip.id) })
            }
        case .adjustment:
            tool("調整", "slider.horizontal.3", panel: .adjust)
            tool("フィルター", "camera.filters", panel: .filters)
            tool("エフェクト", "wand.and.rays", panel: .effects)
            tool("範囲", "circle.dashed", panel: .mask)
        }
    }

    @ViewBuilder
    private func visualTools(_ clip: Clip) -> some View {
        tool("変形", "arrow.up.left.and.arrow.down.right", panel: .transform)
        if advanced { tool("調整", "slider.horizontal.3", panel: .adjust) }
        tool("フィルター", "camera.filters", panel: .filters)
        tool("エフェクト", "wand.and.rays", panel: .effects)
        tool("アニメ", "sparkles", panel: .animation)
        if advanced {
            tool("マスク", "circle.dashed", panel: .mask)
            tool("クロマキー", "person.crop.square.filled.and.at.rectangle", panel: .chroma)
            tool("ブレンド", "square.stack.3d.down.right", panel: .blend)
        }
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
