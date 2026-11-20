import SwiftUI
import UniformTypeIdentifiers

/// 編集画面。端末の向きと大きさに合わせて配置を切り替える（Q61）。
struct EditorView: View {
    @StateObject private var controller: EditorController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.horizontalSizeClass) private var horizontalSize
    let onClose: () -> Void

    @State private var showExport: Bool = false
    @State private var showRename: Bool = false
    @State private var renameText: String = ""

    init(project: Project, onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: EditorController(project: project))
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay(alignment: .top) { ToastView(text: controller.toast) }
        .overlay { JobOverlay(controller: controller) }
        .alert(item: $controller.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showExport) {
            ExportView(controller: controller)
        }
        .alert("プロジェクト名", isPresented: $showRename) {
            TextField("名前", text: $renameText)
            Button("変更") { controller.rename(renameText) }
            Button("キャンセル", role: .cancel) {}
        }
        .background(KeyboardShortcuts(controller: controller, settings: settings, showExport: $showExport))
        .onDrop(of: [.movie, .image, .audio, .gif], isTargeted: nil) { providers in
            controller.handleDrop(providers, copy: settings.copyMediaOnImport, autoProxy: settings.autoProxy)
        }
        .onAppear {
            controller.snapping = settings.snapping
        }
        .preferredColorScheme(settings.colorScheme)
    }

    private func content(size: CGSize) -> some View {
        let landscape: Bool = size.width > size.height && size.width > 700
        let compact: Bool = horizontalSize == .compact || size.width < 600
        let timelineHeight: CGFloat = max(170, min(320, size.height * (landscape ? 0.34 : 0.3)))
        let side: Bool = landscape && settings.inspectorPosition != .bottom && controller.panel != nil
        return VStack(spacing: 0) {
            EditorTopBar(controller: controller, onClose: close, onExport: { showExport = true }, onRename: {
                renameText = controller.project.name
                showRename = true
            })
            if settings.toolbarAtTop {
                EditorToolbar(controller: controller)
            }
            if side {
                HStack(spacing: 0) {
                    if settings.inspectorPosition == .left {
                        InspectorContainer(controller: controller).frame(width: min(380, size.width * 0.34))
                    }
                    previewColumn
                    if settings.inspectorPosition == .right {
                        InspectorContainer(controller: controller).frame(width: min(380, size.width * 0.34))
                    }
                }
            } else {
                previewColumn
                if controller.panel != nil {
                    InspectorContainer(controller: controller).frame(height: min(300, size.height * 0.32))
                }
            }
            if !settings.toolbarAtTop {
                EditorToolbar(controller: controller)
            }
            TimelineRepresentable(controller: controller, colorBlind: settings.colorBlindPalette, compact: compact)
                .frame(height: timelineHeight)
        }
    }

    private var previewColumn: some View {
        VStack(spacing: 0) {
            PreviewArea(controller: controller)
            TransportBar(controller: controller, clock: controller.clock)
        }
    }

    private func close() {
        controller.close()
        onClose()
    }
}

/// 上の帯：戻る・名前・元に戻す・やり直し・保存・書き出し。
struct EditorTopBar: View {
    @ObservedObject var controller: EditorController
    let onClose: () -> Void
    let onExport: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                DVLabel("ホーム", icon: "editor.home")
            }
            .accessibilityLabel("ホームに戻る")
            Button(action: onRename) {
                Text(controller.project.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer()
            Button { controller.undo() } label: { DVImage("editor.undo") }
                .disabled(!controller.canUndo)
                .accessibilityLabel("元に戻す")
            Button { controller.redo() } label: { DVImage("editor.redo") }
                .disabled(!controller.canRedo)
                .accessibilityLabel("やり直し")
            Button { controller.manualSave() } label: { DVImage("editor.save") }
                .accessibilityLabel("保存")
            Button(action: onExport) {
                HStack(spacing: 6) {
                    DVImage("editor.export")
                    Text("書き出し")
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                            in: Capsule())
                .foregroundStyle(Color.black)
                .shadow(color: Theme.accent.opacity(0.45), radius: 6)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("書き出し")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }
}

/// 下に出るパネルの入れ物。
struct InspectorContainer: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(controller.panel?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    controller.panel = nil
                } label: {
                    DVImage("status.close")
                        .foregroundStyle(Theme.subtext)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("閉じる")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            ScrollView {
                PanelRouter.view(for: controller.panel, controller: controller)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .background(Theme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// パネルの振り分け（型チェックを軽くするため AnyView で返す）。
enum PanelRouter {
    @MainActor
    static func view(for panel: EditorPanel?, controller: EditorController) -> AnyView {
        guard let panel = panel else { return AnyView(EmptyView()) }
        switch panel {
        case .media: return AnyView(MediaPanel(controller: controller))
        case .audioLibrary: return AnyView(AudioLibraryPanel(controller: controller))
        case .text: return AnyView(TextPanel(controller: controller))
        case .stickers: return AnyView(StickerPanel(controller: controller))
        case .effects: return AnyView(EffectsPanel(controller: controller))
        case .filters: return AnyView(FiltersPanel(controller: controller))
        case .adjust: return AnyView(AdjustPanel(controller: controller))
        case .transform: return AnyView(TransformPanel(controller: controller))
        case .speed: return AnyView(SpeedPanel(controller: controller))
        case .volume: return AnyView(VolumePanel(controller: controller))
        case .audioFX: return AnyView(AudioFXPanel(controller: controller))
        case .transition: return AnyView(TransitionPanel(controller: controller))
        case .animation: return AnyView(AnimationPanel(controller: controller))
        case .mask: return AnyView(MaskPanel(controller: controller))
        case .chroma: return AnyView(ChromaPanel(controller: controller))
        case .blend: return AnyView(BlendPanel(controller: controller))
        case .subtitles: return AnyView(SubtitlesPanel(controller: controller))
        case .ai: return AnyView(AIPanel(controller: controller))
        case .canvas: return AnyView(CanvasPanel(controller: controller))
        case .keyframes: return AnyView(KeyframesPanel(controller: controller))
        case .reorder: return AnyView(ReorderPanel(controller: controller))
        case .drawing: return AnyView(DrawingPanel(controller: controller))
        case .object3D: return AnyView(Object3DPanel(controller: controller))
        }
    }
}

/// 一時的なお知らせ。
struct ToastView: View {
    let text: String?

    var body: some View {
        if let text = text {
            Text(text)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 60)
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// 処理中の表示（中止ボタン付き）。
struct JobOverlay: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let job = controller.job {
            ZStack {
                Color.black.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    Text(job.title).font(.headline)
                    ProgressView(value: min(1, max(0, job.progress)))
                        .frame(width: 240)
                    Text("\(Int(job.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.subtext)
                    Button("中止", role: .cancel) { controller.cancelJob() }
                }
                .padding(24)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
}

/// キーボードショートカット（Q62, Q70）。見えないボタンにショートカットを割り当てる。
struct KeyboardShortcuts: View {
    @ObservedObject var controller: EditorController
    @ObservedObject var settings: AppSettings
    @Binding var showExport: Bool

    var body: some View {
        ZStack {
            shortcut(.playPause) { controller.togglePlay() }
            shortcut(.split) { controller.splitAtPlayhead() }
            shortcut(.delete) { controller.deleteSelection(ripple: false) }
            shortcut(.rippleDelete) { controller.deleteSelection(ripple: true) }
            shortcut(.undo) { controller.undo() }
            shortcut(.redo) { controller.redo() }
            shortcut(.save) { controller.manualSave() }
            shortcut(.export) { showExport = true }
            shortcut(.previousFrame) { controller.step(-1) }
            shortcut(.nextFrame) { controller.step(1) }
            shortcut(.marker) { controller.toggleMarker() }
            shortcut(.zoomIn) { controller.zoom = min(1200, controller.zoom * 1.4) }
            shortcut(.zoomOut) { controller.zoom = max(4, controller.zoom / 1.4) }
            shortcut(.inPoint) { controller.setInPoint() }
            shortcut(.outPoint) { controller.setOutPoint() }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func shortcut(_ action: ShortcutAction, _ perform: @escaping () -> Void) -> some View {
        Button(action.label, action: perform)
            .keyboardShortcut(settings.key(for: action), modifiers: action.modifiers)
    }
}
