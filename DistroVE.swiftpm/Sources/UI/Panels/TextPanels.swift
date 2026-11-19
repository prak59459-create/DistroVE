import SwiftUI
import UIKit
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

/// テキスト（Q46）。選んでいなければ見本から追加、選んでいれば編集。
struct TextPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip, let text = clip.text {
            TextEditorPanel(controller: controller, clip: clip, text: text)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                PanelTitle(text: "スタイルを選んで追加")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(TextPresets.all, id: \.id) { preset in
                        Button {
                            controller.addText(preset)
                        } label: {
                            Text(preset.name)
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(preset.content.color.color)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct TextEditorPanel: View {
    @ObservedObject var controller: EditorController
    let clip: Clip
    let text: TextContent
    @State private var fonts: [String] = TextEditorPanel.fontFamilies()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("テキスト", text: Binding<String>(get: { text.string }, set: { v in
                change("テキスト") { $0.string = v }
            }), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            HStack {
                Menu {
                    Button("システム（標準）") { change("フォント") { $0.fontName = "" } }
                    ForEach(fonts, id: \.self) { family in
                        Button(family) { change("フォント") { $0.fontName = family } }
                    }
                } label: {
                    Label(text.fontName.isEmpty ? "システム" : text.fontName, systemImage: "textformat")
                        .lineLimit(1)
                }
                Toggle("太字", isOn: Binding<Bool>(get: { text.bold }, set: { v in change("太字") { $0.bold = v } }))
                    .toggleStyle(.button)
                Toggle("斜体", isOn: Binding<Bool>(get: { text.italic }, set: { v in change("斜体") { $0.italic = v } }))
                    .toggleStyle(.button)
                Picker("揃え", selection: Binding<TextAlign>(get: { text.align }, set: { v in change("揃え") { $0.align = v } })) {
                    ForEach(TextAlign.allCases, id: \.self) { a in Text(a.label).tag(a) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
            }
            .font(.footnote)
            ParamRow(label: "大きさ", range: 0.02...0.3, value: text.size, onChange: { v in change("文字の大きさ", key: "size") { $0.size = v } })
            colorRow("文字の色", text.color) { $0.color = $1 }
            ParamRow(label: "縁取り", range: 0...0.3, value: text.strokeWidth, onChange: { v in change("縁取り", key: "stroke") { $0.strokeWidth = v } })
            colorRow("縁取りの色", text.strokeColor) { $0.strokeColor = $1 }
            ParamRow(label: "影", range: 0...0.5, value: text.shadowBlur, onChange: { v in change("影", key: "shadow") { $0.shadowBlur = v } })
            colorRow("影の色", text.shadowColor) { $0.shadowColor = $1 }
            ParamRow(label: "字間", range: -0.1...0.5, value: text.kerning, onChange: { v in change("字間", key: "kern") { $0.kerning = v } })
            ParamRow(label: "行間", range: 0...1, value: text.lineSpacing, onChange: { v in change("行間", key: "line") { $0.lineSpacing = v } })
            colorRow("背景の帯", text.backgroundColor) { $0.backgroundColor = $1 }
            ParamRow(label: "折り返し幅", range: 0.2...1, value: text.maxWidth, onChange: { v in change("折り返し幅", key: "wrap") { $0.maxWidth = v } })
            PanelTitle(text: "動き")
            ChipPicker(items: TextAnimation.allCases, selection: text.animation, label: { $0.label }) { a in
                change("テキストの動き") { $0.animation = a }
            }
        }
    }

    private func change(_ name: String, key: String? = nil, _ body: @escaping (inout TextContent) -> Void) {
        controller.updateSelected(name, coalesce: key.map { "text-\($0)" } ?? "text-\(name)") { c in
            if var t = c.text {
                body(&t)
                c.text = t
                if c.kind == .text { c.name = t.string.components(separatedBy: "\n").first ?? c.name }
            }
        }
    }

    private func colorRow(_ label: String, _ value: RGBA, _ set: @escaping (inout TextContent, RGBA) -> Void) -> some View {
        ColorPicker(label, selection: Binding<Color>(get: { value.color }, set: { c in
            change(label, key: label) { set(&$0, RGBA(c)) }
        }))
        .font(.footnote)
    }

    static func fontFamilies() -> [String] {
        return UIFont.familyNames.sorted()
    }
}

/// 字幕（Q56〜Q60）。手入力・SRT の読み込みと書き出し・スタイル・話者の色・ずれ補正・自動翻訳。
struct SubtitlesPanel: View {
    @ObservedObject var controller: EditorController
    @State private var showImporter: Bool = false
    @State private var shareURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { controller.addCueAtPlayhead() } label: { Label("ここに字幕を追加", systemImage: "plus") }
                Button { controller.panel = .ai } label: { Label("自動字幕", systemImage: "waveform.badge.mic") }
                Button { showImporter = true } label: { Label("SRT 読み込み", systemImage: "square.and.arrow.down") }
                if let url = controller.exportSRT(translation: false) {
                    ShareLink(item: url) { Label("SRT 書き出し", systemImage: "square.and.arrow.up") }
                }
            }
            .buttonStyle(.bordered)
            .font(.caption)
            if let cue = controller.selectedCue {
                CueEditor(controller: controller, cue: cue)
            }
            if let track = controller.subtitleTrack {
                SubtitleStyleEditor(controller: controller, track: track)
                TranslationSection(controller: controller)
                PanelTitle(text: "字幕の一覧（\(track.cues.count) 件）")
                ForEach(track.cues) { cue in
                    Button {
                        controller.selectCue(cue.id)
                        controller.seek(to: cue.start + track.subtitleOffset)
                    } label: {
                        HStack(alignment: .top) {
                            Text(cue.start.shortLabel).font(.caption.monospacedDigit()).foregroundStyle(Theme.subtext)
                            Text(cue.text).font(.footnote).lineLimit(2)
                            Spacer()
                        }
                        .padding(6)
                        .background(cue.id == controller.selectedCueID ? Theme.accent.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                controller.importSRT(url)
            }
        }
    }
}

struct CueEditor: View {
    @ObservedObject var controller: EditorController
    let cue: SubtitleCue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(text: "選んだ字幕")
            TextField("字幕", text: Binding<String>(get: { cue.text }, set: { v in controller.updateCue(cue.id) { $0.text = v } }), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack {
                Text("開始 " + cue.start.timecode(fps: controller.project.canvas.fps)).font(.caption.monospacedDigit())
                Button("−") { nudge(start: true, -0.1) }
                Button("＋") { nudge(start: true, 0.1) }
                Button("再生位置に") { setToPlayhead(start: true) }
                Spacer()
            }
            HStack {
                Text("終了 " + cue.end.timecode(fps: controller.project.canvas.fps)).font(.caption.monospacedDigit())
                Button("−") { nudge(start: false, -0.1) }
                Button("＋") { nudge(start: false, 0.1) }
                Button("再生位置に") { setToPlayhead(start: false) }
                Spacer()
            }
            HStack {
                Text("話者").font(.caption)
                Picker("話者", selection: Binding<Int>(get: { cue.speaker }, set: { v in controller.updateCue(cue.id, name: "話者") { $0.speaker = v } })) {
                    ForEach(0..<5, id: \.self) { i in Text(i == 0 ? "既定" : "話者 \(i)").tag(i) }
                }
                .pickerStyle(.segmented)
            }
            if let translated = cue.translation {
                Text("翻訳：" + translated).font(.caption).foregroundStyle(Theme.subtext)
            }
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func nudge(start: Bool, _ seconds: Double) {
        let delta = Time(seconds: seconds)
        controller.updateCue(cue.id, name: "字幕の時間") { c in
            if start {
                c.start = max(.zero, min(c.end - Time(seconds: 0.1), c.start + delta))
            } else {
                c.end = max(c.start + Time(seconds: 0.1), c.end + delta)
            }
        }
    }

    private func setToPlayhead(start: Bool) {
        let t: Time = controller.currentTime
        controller.updateCue(cue.id, name: "字幕の時間") { c in
            if start {
                if t < c.end { c.start = t }
            } else {
                if t > c.start { c.end = t }
            }
        }
    }
}

struct SubtitleStyleEditor: View {
    @ObservedObject var controller: EditorController
    let track: Track

    var body: some View {
        let style: SubtitleStyle = track.subtitleStyle
        VStack(alignment: .leading, spacing: 4) {
            PanelTitle(text: "字幕のスタイル")
            ParamRow(label: "大きさ", range: 0.02...0.12, value: style.size, onChange: { v in controller.updateSubtitleStyle { $0.size = v } })
            ParamRow(label: "縁取り", range: 0...0.3, value: style.strokeWidth, onChange: { v in controller.updateSubtitleStyle { $0.strokeWidth = v } })
            ParamRow(label: "下からの位置", range: 0.02...0.5, value: style.bottomMargin, onChange: { v in controller.updateSubtitleStyle { $0.bottomMargin = v } })
            ColorPicker("文字の色", selection: Binding<Color>(get: { style.color.color }, set: { c in controller.updateSubtitleStyle { $0.color = RGBA(c) } }))
                .font(.footnote)
            ColorPicker("背景の帯", selection: Binding<Color>(get: { style.bandColor.color }, set: { c in controller.updateSubtitleStyle { $0.bandColor = RGBA(c) } }))
                .font(.footnote)
            ChipPicker(items: TextAnimation.allCases, selection: style.animation, label: { $0.label }) { a in
                controller.updateSubtitleStyle { $0.animation = a }
            }
            ParamRow(label: "ずれ補正", range: -3...3, value: track.subtitleOffset.seconds, format: "%+.2f秒", onChange: { v in
                controller.setSubtitleOffset(v)
            })
            Toggle("翻訳も表示する", isOn: Binding<Bool>(get: { style.showTranslation }, set: { v in controller.updateSubtitleStyle { $0.showTranslation = v } }))
                .font(.footnote)
        }
    }
}

/// 字幕の自動翻訳（Q58）。iPadOS 18 以降の端末内翻訳（Translation フレームワーク）を使う。
struct TranslationSection: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            SubtitleTranslator(controller: controller)
        } else {
            unavailable
        }
        #else
        unavailable
        #endif
    }

    private var unavailable: some View {
        Text("自動翻訳は iPadOS 18 以降で使えます。")
            .font(.caption)
            .foregroundStyle(Theme.subtext)
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
struct SubtitleTranslator: View {
    @ObservedObject var controller: EditorController
    @State private var target: String = "en"
    @State private var configuration: TranslationSession.Configuration?
    @State private var shareURL: URL?

    private let languages: [(String, String)] = [("en", "英語"), ("zh-Hans", "中国語（簡体）"), ("ko", "韓国語"), ("es", "スペイン語"), ("fr", "フランス語")]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(text: "自動翻訳（端末内）")
            HStack {
                Picker("翻訳先", selection: $target) {
                    ForEach(languages, id: \.0) { item in Text(item.1).tag(item.0) }
                }
                Button("翻訳する") {
                    configuration = TranslationSession.Configuration(source: Locale.Language(identifier: "ja"), target: Locale.Language(identifier: target))
                }
                .buttonStyle(.borderedProminent)
                if let url = controller.exportSRT(translation: true) {
                    ShareLink(item: url) { Label("翻訳 SRT", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
            }
            .font(.caption)
        }
        .translationTask(configuration) { session in
            await translate(session)
        }
    }

    private func translate(_ session: TranslationSession) async {
        guard let track = controller.subtitleTrack, !track.cues.isEmpty else { return }
        var requests: [TranslationSession.Request] = []
        for cue in track.cues {
            requests.append(TranslationSession.Request(sourceText: cue.text, clientIdentifier: cue.id.uuidString))
        }
        do {
            let responses: [TranslationSession.Response] = try await session.translations(from: requests)
            var results: [UUID: String] = [:]
            for response in responses {
                if let key = response.clientIdentifier, let id = UUID(uuidString: key) {
                    results[id] = response.targetText
                }
            }
            let language: String = target
            controller.apply("自動翻訳") { p in
                for t in p.tracks.indices where p.tracks[t].kind == .subtitle {
                    for i in p.tracks[t].cues.indices {
                        if let translated = results[p.tracks[t].cues[i].id] {
                            p.tracks[t].cues[i].translation = translated
                        }
                    }
                    p.tracks[t].subtitleStyle.translationLanguage = language
                    p.tracks[t].subtitleStyle.showTranslation = true
                }
            }
            controller.showToast("\(responses.count) 件を翻訳しました")
        } catch {
            controller.alert = EditorAlert(title: "翻訳できませんでした", message: error.localizedDescription)
        }
        configuration = nil
    }
}
#endif
