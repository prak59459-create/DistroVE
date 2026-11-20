import Photos
import SwiftUI

/// 書き出し（Q72〜Q76, Q80, Q83）。透かしは入れない。投稿はせず、写真ライブラリかファイルに保存する。
struct ExportView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ExportModel()
    @State private var settings: ExportSettings = ExportSettings()
    @State private var presetID: String?
    @State private var useRange: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                presetSection
                formatSection
                summarySection
                actionSection
            }
            .navigationTitle("書き出し")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { prepare() }
    }

    private func prepare() {
        var initial: ExportSettings = controller.project.lastExport ?? ExportSettings()
        if controller.project.lastExport == nil {
            initial.fps = Int(min(60, controller.project.canvas.fps.rounded()))
        }
        settings = controller.limits.clamp(initial)
        controller.pause()
    }

    private var presetSection: some View {
        Section("投稿先のプリセット") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ExportPreset.all) { preset in
                        presetButton(preset)
                    }
                }
                .padding(.vertical, 4)
            }
            if let note = aspectNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.subtext)
            }
        }
    }

    private var aspectNote: String? {
        guard let preset = ExportPreset.all.first(where: { $0.id == presetID }), let aspect = preset.aspect else { return nil }
        let current: AspectPreset = controller.project.canvas.aspect
        if aspect == current { return nil }
        return "このプリセットは \(aspect.label) 向けです。今の画面は \(current.label) なので、上下か左右に余白が付きます（「画面」で縦横比を変えられます）。"
    }

    private var formatSection: some View {
        Section("形式") {
            Picker("形式", selection: $settings.format) {
                ForEach(ExportFormat.allCases, id: \.self) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented)
            if settings.format == .mp4 {
                videoOptions
            } else {
                Stepper("GIF のコマ数：\(settings.gifFps)fps", value: $settings.gifFps, in: 5...24)
                Stepper("GIF の幅：\(settings.gifMaxWidth)px", value: $settings.gifMaxWidth, in: 160...960, step: 80)
            }
            if controller.project.playRange != nil {
                Toggle("範囲指定の部分だけ書き出す", isOn: $useRange)
            }
        }
    }

    @ViewBuilder
    private var videoOptions: some View {
        Picker("コーデック", selection: $settings.codec) {
            ForEach(VideoCodec.allCases, id: \.self) { c in Text(c.label).tag(c) }
        }
        .disabled(!controller.limits.supportsHEVC)
        Picker("解像度", selection: $settings.resolution) {
            ForEach(allowedResolutions, id: \.self) { r in Text(r.label).tag(r) }
        }
        Picker("フレームレート", selection: $settings.fps) {
            ForEach(allowedFrameRates, id: \.self) { f in Text("\(f)fps").tag(f) }
        }
        Toggle("音声を含める", isOn: $settings.includeAudio)
        bitrateRow
    }

    private var allowedResolutions: [ExportResolution] {
        return ExportResolution.allCases.filter { controller.limits.allows($0) }
    }

    private var allowedFrameRates: [Int] {
        return ExportSettings.frameRates.filter { controller.limits.allows(fps: $0) }
    }

    private var summarySection: some View {
        Section {
            summary
            if let warning = storageWarning {
                DVLabel(warning, icon: "status.warning")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let note = limitNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.subtext)
            }
        }
    }

    private var limitNote: String? {
        let limits: DeviceLimits = controller.limits
        if limits.maxResolution == .p2160 && limits.maxFps >= 120 { return nil }
        return "この端末では \(limits.maxResolution.label)・\(limits.maxFps)fps まで選べます。"
    }

    private var actionSection: some View {
        Section {
            if model.isExporting {
                ProgressView(value: model.progress) {
                    Text("書き出し中… \(Int(model.progress * 100))%")
                }
                Button("中止", role: .destructive) { model.cancel() }
            } else if let url = model.output {
                finishedActions(url)
            } else {
                Button {
                    start()
                } label: {
                    DVLabel("書き出す", icon: "export.start")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(Theme.subtext)
            }
        }
    }

    @ViewBuilder
    private func finishedActions(_ url: URL) -> some View {
        HStack(spacing: 12) {
            DVImage("illustration.exported")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            DVLabel("書き出しました", icon: "status.done")
                .foregroundStyle(.green)
        }
        Button {
            model.saveToPhotos(url, isGIF: settings.format == .gif)
        } label: {
            DVLabel("写真ライブラリに保存", icon: "export.photos")
        }
        ShareLink(item: url) {
            DVLabel("ファイルに保存・共有", icon: "export.share")
        }
    }

    private func presetButton(_ preset: ExportPreset) -> some View {
        Button {
            presetID = preset.id
            settings = controller.limits.clamp(preset.settings)
        } label: {
            HStack(spacing: 8) {
                DVImage("export." + preset.id)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(presetID == preset.id ? Theme.accent : Theme.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.footnote.weight(.semibold))
                    Text(preset.detail).font(.caption2).foregroundStyle(Theme.subtext)
                }
            }
            .padding(10)
            .background(presetID == preset.id ? Theme.accent.opacity(0.25) : Theme.raised, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(presetID == preset.id ? Theme.accent : Color.clear, lineWidth: 1))
        }
        .buttonStyle(PressScaleStyle())
    }

    private var bitrateRow: some View {
        let size: (width: Int, height: Int) = settings.outputSize(canvasWidth: controller.project.canvas.width, canvasHeight: controller.project.canvas.height)
        let auto: Double = Double(settings.effectiveBitrate(width: size.width, height: size.height)) / 1_000_000
        return VStack(alignment: .leading) {
            Toggle("ビットレートを自動で決める", isOn: Binding<Bool>(get: { settings.bitrateMbps == nil }, set: { v in
                settings.bitrateMbps = v ? nil : auto.rounded()
            }))
            if let mbps = settings.bitrateMbps {
                Slider(value: Binding<Double>(get: { mbps }, set: { settings.bitrateMbps = $0.rounded() }), in: 2...150)
                Text("\(Int(mbps)) Mbps").font(.caption.monospacedDigit())
            } else {
                Text(String(format: "自動：約 %.0f Mbps", auto)).font(.caption).foregroundStyle(Theme.subtext)
            }
        }
    }

    private var effectiveSettings: ExportSettings {
        var s: ExportSettings = settings
        s.range = useRange ? controller.project.playRange : nil
        return s
    }

    private var summary: some View {
        let s: ExportSettings = effectiveSettings
        let canvas: CanvasSettings = controller.project.canvas
        let size: (width: Int, height: Int) = s.format == .gif ? s.gifSize(canvasWidth: canvas.width, canvasHeight: canvas.height)
            : s.outputSize(canvasWidth: canvas.width, canvasHeight: canvas.height)
        let duration: Time = s.range?.duration ?? controller.project.duration
        let bytes: Int64 = s.estimatedBytes(duration: duration, width: size.width, height: size.height)
        let formatter = ByteCountFormatter()
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(size.width) × \(size.height) ・ \(duration.shortLabel)").font(.footnote.monospacedDigit())
            if s.format == .mp4 {
                Text("およそ " + formatter.string(fromByteCount: bytes)).font(.caption).foregroundStyle(Theme.subtext)
            }
            Text("透かしは入りません。").font(.caption).foregroundStyle(Theme.subtext)
        }
    }

    private var storageWarning: String? {
        let s: ExportSettings = effectiveSettings
        let size: (width: Int, height: Int) = s.outputSize(canvasWidth: controller.project.canvas.width, canvasHeight: controller.project.canvas.height)
        let duration: Time = s.range?.duration ?? controller.project.duration
        return CacheManager.storageWarning(needed: s.estimatedBytes(duration: duration, width: size.width, height: size.height))
    }

    private func start() {
        let s: ExportSettings = effectiveSettings
        controller.apply("書き出し設定") { p in p.lastExport = s }
        controller.saveNow(backup: false)
        model.export(project: controller.project, settings: s)
    }
}

@MainActor
final class ExportModel: ObservableObject {
    @Published var isExporting: Bool = false
    @Published var progress: Double = 0
    @Published var output: URL?
    @Published var message: String?
    private var exporter: Exporter?
    private var task: Task<Void, Never>?

    func export(project: Project, settings: ExportSettings) {
        let ext: String = settings.format == .gif ? "gif" : "mp4"
        let url: URL = AppPaths.cacheFolder("Exports").appendingPathComponent(AppPaths.sanitize(project.name) + "." + ext)
        let exporter = Exporter()
        self.exporter = exporter
        isExporting = true
        progress = 0
        message = nil
        output = nil
        let started = Date()
        task = Task { [weak self] in
            do {
                try await exporter.export(project: project, settings: settings, to: url, progress: { value in
                    Task { @MainActor [weak self] in self?.progress = value }
                })
                self?.output = url
                let seconds: Double = Date().timeIntervalSince(started)
                self?.message = String(format: "%.1f 秒で書き出しました。", seconds)
                Diagnostics.shared.count("書き出し")
            } catch EngineError.cancelled {
                self?.message = "中止しました。"
            } catch {
                self?.message = "書き出しに失敗しました：" + error.localizedDescription
                Diagnostics.shared.log("export failed: \(error)")
            }
            self?.isExporting = false
        }
    }

    func cancel() {
        exporter?.cancel()
        task?.cancel()
    }

    func saveToPhotos(_ url: URL, isGIF: Bool) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            Task { @MainActor [weak self] in
                guard status == .authorized || status == .limited else {
                    self?.message = "写真ライブラリへの追加が許可されていません（設定 App で変更できます）。"
                    return
                }
                do {
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        request.addResource(with: isGIF ? .photo : .video, fileURL: url, options: nil)
                    }
                    self?.message = "写真ライブラリに保存しました。"
                } catch {
                    self?.message = "保存できませんでした：" + error.localizedDescription
                }
            }
        }
    }
}
