import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 素材の追加（Q37, Q49, Q67）。
struct MediaPanel: View {
    @ObservedObject var controller: EditorController
    @EnvironmentObject private var settings: AppSettings
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFiles: Bool = false
    @State private var asOverlay: Bool = false
    @State private var showCamera: Bool = false
    @State private var showNarration: Bool = false
    @StateObject private var screen = ScreenRecorderModel()

    var body: some View {
        withImporters(sections)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("重ねて追加（ピクチャーインピクチャー）", isOn: $asOverlay)
                .font(.footnote)
            importButtons
            Text(settings.copyMediaOnImport ? "ファイルはアプリ内にコピーして取り込みます（設定で「参照のみ」に変えられます）。" : "ファイルは元の場所を参照します（容量を使いません）。")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
            PanelTitle(text: "撮影・録音・録画")
            recordButtons
            PanelTitle(text: "単色・調整")
            solidButtons
            if !controller.project.media.isEmpty {
                PanelTitle(text: "このプロジェクトの素材")
                ProjectMediaList(controller: controller)
            }
        }
    }

    private var importButtons: some View {
        HStack(spacing: 10) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 50, matching: .any(of: [.videos, .images])) {
                DVLabel("写真ライブラリ", icon: "media.photos")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button {
                showFiles = true
            } label: {
                DVLabel("ファイル・クラウド", icon: "media.files")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var recordButtons: some View {
        HStack(spacing: 10) {
            Button { showCamera = true } label: { DVLabel("カメラで撮影", icon: "media.camera") }
            Button { showNarration = true } label: { DVLabel("ナレーション", icon: "media.narration") }
            Button {
                screen.toggle { url in
                    controller.importFiles([url], copy: true, asOverlay: false, autoProxy: false)
                }
            } label: {
                DVLabel(screen.isRecording ? "画面録画を止める" : "画面録画", icon: screen.isRecording ? "media.screenRecordStop" : "media.screenRecord")
            }
        }
        .buttonStyle(.bordered)
    }

    private var solidButtons: some View {
        HStack(spacing: 10) {
            ForEach(["#000000", "#FFFFFF", "#FF7A1A", "#3D7BFF", "#22B566", "#FF4F87"], id: \.self) { hex in
                SolidSwatch(hex: hex) { controller.addSolid(RGBA(hex: hex) ?? .black) }
            }
            Button("調整レイヤー") { controller.addAdjustmentLayer() }
                .buttonStyle(.bordered)
        }
    }

    private func withImporters<V: View>(_ view: V) -> some View {
        view
            .onChange(of: photoItems) { _, items in
                if items.isEmpty { return }
                controller.importPhotos(items, asOverlay: asOverlay, autoProxy: settings.autoProxy)
                photoItems = []
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .audio, .image, .gif, .item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    controller.importFiles(urls, copy: settings.copyMediaOnImport, asOverlay: asOverlay, autoProxy: settings.autoProxy)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraRecorderView { url in
                    showCamera = false
                    if let url = url {
                        controller.importFiles([url], copy: true, asOverlay: asOverlay, autoProxy: settings.autoProxy)
                    }
                }
            }
            .sheet(isPresented: $showNarration) {
                NarrationRecorderView { url in
                    showNarration = false
                    if let url = url {
                        controller.importFiles([url], copy: true, asOverlay: false, autoProxy: false)
                    }
                }
            }
    }
}

/// 単色クリップの見本（押すと追加）。
struct SolidSwatch: View {
    let hex: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill((RGBA(hex: hex) ?? .black).color)
                .frame(width: 36, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("単色 \(hex)")
    }
}

/// プロジェクト内の素材の一覧（もう一度タイムラインに置く・プロキシを作る）。
struct ProjectMediaList: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        ForEach(controller.project.media) { asset in
            HStack {
                DVImage(asset.kind.iconID)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name).font(.footnote).lineLimit(1)
                    Text(detail(asset)).font(.caption2).foregroundStyle(Theme.subtext)
                }
                Spacer()
                if asset.kind == .video && asset.proxyPath == nil {
                    Button("プロキシ") { makeProxy(asset) }
                        .font(.caption)
                }
                Button {
                    controller.addAssets([asset], asOverlay: false, autoProxy: false)
                } label: {
                    DVImage("media.add")
                }
                .accessibilityLabel("タイムラインに追加")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
        }
    }

    private func detail(_ asset: MediaAsset) -> String {
        var parts: [String] = []
        if asset.width > 0 { parts.append("\(asset.width)×\(asset.height)") }
        if asset.duration.isPositive { parts.append(asset.duration.shortLabel) }
        if !asset.codec.isEmpty { parts.append(asset.codec) }
        if asset.proxyPath != nil { parts.append("プロキシあり") }
        if asset.storage == .referenced { parts.append("参照") }
        return parts.joined(separator: " · ")
    }

    private func makeProxy(_ asset: MediaAsset) {
        let id: UUID = asset.id
        controller.runJob("プロキシの作成") { c, _ in
            let path: String = try await MediaJobs.makeProxy(for: asset)
            c.apply("プロキシ作成") { p in
                if let i = p.media.firstIndex(where: { $0.id == id }) { p.media[i].proxyPath = path }
            }
            c.useProxies = true
        }
    }
}

/// 内蔵の BGM・効果音（Q54, Q55）。
struct AudioLibraryPanel: View {
    @ObservedObject var controller: EditorController
    @State private var previewPlayer: AVAudioPlayer?
    @State private var playingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTitle(text: "BGM")
            ForEach(SoundLibrary.all.filter { $0.category == .bgm }) { sound in
                row(sound)
            }
            PanelTitle(text: "効果音")
            ForEach(SoundLibrary.all.filter { $0.category == .sfx }) { sound in
                row(sound)
            }
            Text("同梱の BGM・効果音は、アプリが端末内で合成した音源です。作った動画に自由に使えます。ほかの曲や効果音を使うときは、権利者の利用条件を必ず確認してください。")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
        }
        .onDisappear { previewPlayer?.stop() }
    }

    private func row(_ sound: SoundDefinition) -> some View {
        HStack {
            Button {
                togglePreview(sound.id)
            } label: {
                DVImage(playingID == sound.id ? "sound.stop" : "sound.play")
                    .font(.title3)
            }
            .accessibilityLabel("試聴")
            VStack(alignment: .leading, spacing: 2) {
                Text(sound.name).font(.footnote.weight(.medium))
                Text(sound.summary).font(.caption2).foregroundStyle(Theme.subtext)
            }
            Spacer()
            Button("追加") { controller.addLibrarySound(sound.id) }
                .buttonStyle(.bordered)
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
    }

    private func togglePreview(_ id: String) {
        if playingID == id {
            previewPlayer?.stop()
            playingID = nil
            return
        }
        guard let url = try? SoundLibraryStore.ensureFile(id), let player = try? AVAudioPlayer(contentsOf: url) else { return }
        previewPlayer?.stop()
        player.play()
        previewPlayer = player
        playingID = id
    }
}

/// ステッカー・図形・モザイク枠（Q37, Q47）。
struct StickerPanel: View {
    @ObservedObject var controller: EditorController
    private let emojis: [String] = ["😂", "😍", "🔥", "✨", "👍", "👀", "💯", "🎉", "😎", "🥺", "💀", "⚡️", "❤️", "⭐️", "🎵", "📌", "✅", "❗️", "❓", "💥", "🚀", "🌈", "🍀", "😭"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(text: "ステッカー")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 8), spacing: 8) {
                ForEach(emojis, id: \.self) { emoji in
                    Button {
                        controller.addSticker(emoji)
                    } label: {
                        Text(emoji).font(.system(size: 28))
                    }
                    .buttonStyle(.plain)
                }
            }
            PanelTitle(text: "矢印・図形")
            HStack(spacing: 8) {
                ForEach(ShapeKind.allCases, id: \.self) { kind in
                    IconChoiceButton(title: kind.label, icon: kind.iconID) { controller.addShape(kind) }
                }
            }
            PanelTitle(text: "隠す")
            Button {
                controller.addMosaicBox()
            } label: {
                DVLabel("モザイク枠を追加", icon: "media.mosaic")
            }
            .buttonStyle(.bordered)
        }
    }
}

/// 画面サイズ・フレームレート・背景（Q35 の縦横比、Q74）。
struct CanvasPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelTitle(text: "縦横比")
            ChipPicker(items: AspectPreset.allCases, selection: controller.project.canvas.aspect, label: { $0.label }, icon: { $0.iconID }) { aspect in
                controller.setAspect(aspect)
            }
            Text("\(controller.project.canvas.width) × \(controller.project.canvas.height)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.subtext)
            PanelTitle(text: "フレームレート")
            ChipPicker(items: [24.0, 25.0, 29.97, 30.0, 60.0, 120.0], selection: controller.project.canvas.fps, label: { fpsLabel($0) }) { fps in
                controller.setFrameRate(fps)
            }
            ColorPicker("背景色", selection: Binding<Color>(get: { controller.project.canvas.background.color },
                                                         set: { controller.setBackground(RGBA($0)) }), supportsOpacity: false)
                .font(.footnote)
            Toggle("メイントラックを隙間なく詰める（マグネット）", isOn: Binding<Bool>(get: { controller.project.magneticMainTrack },
                                                                       set: { controller.setMagnetic($0) }))
                .font(.footnote)
            Toggle("スナップ（吸着）", isOn: $controller.snapping)
                .font(.footnote)
        }
    }

    private func fpsLabel(_ fps: Double) -> String {
        if abs(fps - fps.rounded()) < 0.001 { return "\(Int(fps))fps" }
        return String(format: "%.2ffps", fps)
    }
}

/// メイントラックを一覧で並べ替える（Q33）。
struct ReorderPanel: View {
    @ObservedObject var controller: EditorController

    private var clips: [Clip] {
        guard let main = controller.project.mainTrackIndex else { return [] }
        return controller.project.tracks[main].clips
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("上下の矢印で順番を入れ替えます。タイムラインでは長押しして動かせます。")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                HStack {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).frame(width: 24)
                    Text(clip.name).font(.footnote).lineLimit(1)
                    Spacer()
                    Text(clip.duration.shortLabel).font(.caption.monospacedDigit()).foregroundStyle(Theme.subtext)
                    Button {
                        move(clip.id, to: index - 1)
                    } label: { DVImage("reorder.up") }
                        .disabled(index == 0)
                    Button {
                        move(clip.id, to: index + 1)
                    } label: { DVImage("reorder.down") }
                        .disabled(index == clips.count - 1)
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 4)
            }
        }
    }

    private func move(_ id: UUID, to index: Int) {
        controller.apply("並べ替え") { p in p.reorderMain(clipID: id, toIndex: index) }
    }
}

/// 手書き（Q47）。
struct DrawingPanel: View {
    @ObservedObject var controller: EditorController
    @State private var showCanvas: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple Pencil や指で描いた線を、画面全体に重ねるクリップとして追加します。")
                .font(.footnote)
                .foregroundStyle(Theme.subtext)
            Button {
                showCanvas = true
            } label: {
                DVLabel("描く", icon: "media.draw")
            }
            .buttonStyle(.borderedProminent)
        }
        .fullScreenCover(isPresented: $showCanvas) {
            DrawingSheet(aspect: CGFloat(controller.project.canvas.width) / CGFloat(max(1, controller.project.canvas.height))) { image in
                showCanvas = false
                if let image = image { controller.addDrawing(image) }
            }
        }
    }
}
