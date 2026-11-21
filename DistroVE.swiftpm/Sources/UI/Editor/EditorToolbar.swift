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
        return tool(item.title, item.iconID, panel: panel, action: action)
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
            tool("キーフレーム", "edit.keyframe", panel: .keyframes)
        }
        tool("分割", "edit.split", action: { controller.splitAtPlayhead() })
        tool("削除", "edit.delete", action: { controller.deleteSelection(ripple: false) })
        if advanced {
            tool("リップル削除", "edit.rippleDelete", action: { controller.deleteSelection(ripple: true) })
        }
        tool("複製", "edit.duplicate", action: { controller.duplicateSelection() })
        kindTools(clip)
        if advanced && !pro {
            tool("キーフレーム", "edit.keyframe", panel: .keyframes)
        }
    }

    @ViewBuilder
    private func kindTools(_ clip: Clip) -> some View {
        switch clip.kind {
        case .video:
            visualTools(clip)
            tool("速度", "edit.speed", panel: .speed)
            tool("音量", "edit.volume", panel: .volume)
            if advanced { tool("音声加工", "edit.audioFX", panel: .audioFX) }
            tool(clip.speed.reversed ? "逆再生 解除" : "逆再生", "edit.reverse", action: { controller.toggleReverse() })
            tool("静止", "edit.freeze", action: { controller.freezeFrame() })
            tool("トランジション", "edit.transition", panel: .transition, enabled: isOnMain(clip))
        case .image, .gif, .solid:
            visualTools(clip)
            tool("トランジション", "edit.transition", panel: .transition, enabled: isOnMain(clip))
        case .text, .sticker:
            tool("編集", "edit.text", panel: .text)
            tool("変形", "edit.transform", panel: .transform)
            tool("アニメ", "edit.animation", panel: .animation)
            if advanced {
                tool("エフェクト", "edit.effects", panel: .effects)
                tool("ブレンド", "edit.blend", panel: .blend)
            }
        case .shape:
            tool("変形", "edit.transform", panel: .transform)
            tool("アニメ", "edit.animation", panel: .animation)
            if advanced { tool("ブレンド", "edit.blend", panel: .blend) }
        case .object3D:
            tool("3D", "edit.object3D", panel: .object3D)
            tool("変形", "edit.transform", panel: .transform)
            tool("アニメ", "edit.animation", panel: .animation)
            if advanced {
                tool("エフェクト", "edit.effects", panel: .effects)
                tool("ブレンド", "edit.blend", panel: .blend)
            }
        case .audio:
            tool("音量", "edit.volume", panel: .volume)
            tool("速度", "edit.speed", panel: .speed)
            if advanced {
                tool("音声加工", "edit.audioFX", panel: .audioFX)
                tool("ビート検出", "edit.beats", action: { controller.detectBeats(clipID: clip.id) })
            }
        case .adjustment:
            tool("調整", "edit.adjust", panel: .adjust)
            tool("フィルター", "edit.filters", panel: .filters)
            tool("エフェクト", "edit.effects", panel: .effects)
            tool("範囲", "edit.mask", panel: .mask)
        }
    }

    @ViewBuilder
    private func visualTools(_ clip: Clip) -> some View {
        tool("変形", "edit.transform", panel: .transform)
        if advanced { tool("調整", "edit.adjust", panel: .adjust) }
        tool("フィルター", "edit.filters", panel: .filters)
        tool("エフェクト", "edit.effects", panel: .effects)
        tool("アニメ", "edit.animation", panel: .animation)
        if advanced {
            tool("マスク", "edit.mask", panel: .mask)
            tool("クロマキー", "edit.chromaKey", panel: .chroma)
            tool("ブレンド", "edit.blend", panel: .blend)
        }
    }

    private func isOnMain(_ clip: Clip) -> Bool {
        guard let loc = controller.project.locate(clip.id) else { return false }
        return loc.track == controller.project.mainTrackIndex && loc.clip > 0
    }

    // MARK: 複数選択・字幕

    @ViewBuilder
    private var multiTools: some View {
        tool("分割", "edit.split", action: { controller.splitAtPlayhead() })
        tool("削除", "edit.delete", action: { controller.deleteSelection(ripple: false) })
        tool("リップル削除", "edit.rippleDelete", action: { controller.deleteSelection(ripple: true) })
        tool("選択解除", "edit.deselect", action: { controller.select(nil) })
    }

    @ViewBuilder
    private var cueTools: some View {
        tool("字幕を編集", "edit.subtitle", panel: .subtitles)
        tool("削除", "edit.delete", action: { controller.deleteSelection(ripple: false) })
        tool("選択解除", "edit.deselect", action: { controller.selectCue(nil) })
    }
}
