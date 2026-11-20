import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 設定 > アイコン。ChatGPT などで作ったアイコンを取り込み、アプリ中のボタン・道具・エフェクトの絵を替える。
/// プロンプト（docs/アイコン制作プロンプト.md と同じ文）をここからコピーできる。
struct IconSettingsView: View {
    private enum ImportMode {
        case files
        case sheet
        case single
    }

    @ObservedObject private var store: IconStore = IconStore.shared
    @State private var style: IconStyle = .proLine
    @State private var sheetIndex: Int = 0
    @State private var layout: IconSheetLayout = .six
    @State private var importMode: ImportMode = .files
    @State private var showImporter: Bool = false
    @State private var sheetPhoto: PhotosPickerItem?
    @State private var singlePhoto: PhotosPickerItem?
    @State private var singleTarget: IconSlot?
    @State private var report: IconImportReport?
    @State private var busy: Bool = false
    @State private var copied: String?
    @State private var confirmReset: Bool = false
    @State private var group: IconGroup = .tools
    @State private var pickSinglePhoto: Bool = false

    // 型チェックが重くならないよう、飾り（取り込み・確認・表示）を関数に分ける
    var body: some View {
        overlays(dialogs(pickers(form)))
    }

    private var form: some View {
        Form {
            introSection
            promptSection
            sheetSection
            importSection
            previewSection
            Section {
                Button("すべて元の絵（SF Symbols）に戻す", role: .destructive) { confirmReset = true }
                    .disabled(store.importedCount == 0)
            }
        }
        .navigationTitle("アイコン")
    }

    private func pickers<V: View>(_ view: V) -> some View {
        view
            .fileImporter(isPresented: $showImporter, allowedContentTypes: allowedTypes, allowsMultipleSelection: importMode == .files) { result in
                handle(result)
            }
            .photosPicker(isPresented: $pickSinglePhoto, selection: $singlePhoto, matching: .images)
            .onChange(of: sheetPhoto) { _, item in
                loadPhoto(item, forSheet: true)
            }
            .onChange(of: singlePhoto) { _, item in
                loadPhoto(item, forSheet: false)
            }
    }

    private func dialogs<V: View>(_ view: V) -> some View {
        let showReport: Binding<Bool> = Binding<Bool>(get: { report != nil }, set: { if !$0 { report = nil } })
        return view
            .confirmationDialog("取り込んだアイコンをすべて消しますか？", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("すべて元に戻す", role: .destructive) { store.removeAll() }
            }
            .alert("取り込み", isPresented: showReport) {
                Button("OK") { report = nil }
            } message: {
                Text(report?.summary ?? "")
            }
    }

    private func overlays<V: View>(_ view: V) -> some View {
        view
            .overlay(alignment: .bottom) {
                if let text = copied {
                    Text(text)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
            .overlay {
                if busy {
                    ProgressView("取り込み中…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
    }

    private var allowedTypes: [UTType] {
        switch importMode {
        case .files: return [.image, .folder]
        case .sheet, .single: return [.image]
        }
    }

    // MARK: 説明

    private var introSection: some View {
        Section {
            HStack(spacing: 14) {
                DVImage("tool.ai")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(IconCatalog.all.count) か所の絵を差し替えられます").font(.headline)
                    Text("ChatGPT で作った画像を取り込むと、ボタンの大きさ・色・ダーク/ライトに合わせて自動で表示します。背景は自動で透明にし、大きさもそろえます。")
                        .font(.footnote)
                        .foregroundStyle(Theme.subtext)
                }
            }
            LabeledContent("取り込み済み", value: "\(store.importedCount) / \(IconCatalog.all.count)")
        }
    }

    // MARK: プロンプト

    private var promptSection: some View {
        Section {
            Picker("絵柄", selection: $style) {
                ForEach(IconStyle.allCases, id: \.self) { s in Text(s.title).tag(s) }
            }
            Text(style.detail).font(.caption).foregroundStyle(Theme.subtext)
            Button {
                copy(IconPrompt.styleGuide(style), "全体の決まりをコピーしました")
            } label: { DVLabel("1. 全体の決まりをコピー（最初に 1 回）", icon: "project.duplicate") }
            Button {
                copy(IconPrompt.appIcon(style), "アプリのアイコンのプロンプトをコピーしました")
            } label: { DVLabel("アプリのアイコンのプロンプトをコピー", icon: "brand.logo") }
        } header: {
            Text("ChatGPT 用のプロンプト")
        } footer: {
            Text("ChatGPT の新しいチャットに「全体の決まり」を送ってから、下のシートを 1 枚ずつ送ります。同じチャットで続けると絵柄がそろいます。アプリのアイコンは Swift Playgrounds の App Settings > App Icon で選びます。")
        }
    }

    private var sheetSection: some View {
        Section {
            Picker("まとめ方", selection: Binding<IconSheetLayout>(get: { layout }, set: { value in
                layout = value
                sheetIndex = 0
            })) {
                ForEach(IconSheetLayout.allCases, id: \.self) { l in Text(l.title).tag(l) }
            }
            Picker("シート", selection: $sheetIndex) {
                ForEach(0..<IconCatalog.sheets(layout).count, id: \.self) { i in
                    Text(IconSettingsView.sheetLabel(i, layout: layout)).tag(i)
                }
            }
            sheetPreview
            Button {
                copy(IconPrompt.sheet(sheetIndex, style: style, layout: layout), "シート \(sheetIndex + 1) のプロンプトをコピーしました")
            } label: { DVLabel("2. このシートのプロンプトをコピー", icon: "project.duplicate") }
            Button {
                copy(IconPrompt.slicing(sheetIndex, layout: layout), "切り分けの依頼をコピーしました")
            } label: { DVLabel("（ZIP でほしいとき）切り分けの依頼をコピー", icon: "edit.split") }
            Button {
                importMode = .sheet
                showImporter = true
            } label: { DVLabel("3. できた画像をファイルから取り込む", icon: "media.files") }
            PhotosPicker(selection: $sheetPhoto, matching: .images) {
                DVLabel("3. できた画像を写真から取り込む", icon: "media.photos")
            }
        } header: {
            Text("シート（並べて作った 1 枚の画像）から切り出す")
        } footer: {
            Text("全部で \(IconCatalog.sheets(layout).count) 枚（1 枚に \(layout.columns) 列 × \(layout.rows) 行）。切り出すとき、並んでいる順に名前を付けます。1 枚に 48 個だと順番を間違えることがあるので、取り込んだら下の一覧で確かめてください。")
        }
    }

    static func sheetLabel(_ index: Int, layout: IconSheetLayout) -> String {
        let title: String = IconCatalog.sheetTitle(index, layout: layout)
        return "\(index + 1)：\(title)"
    }

    private var sheetPreview: some View {
        let all: [[IconSlot]] = IconCatalog.sheets(layout)
        let slots: [IconSlot] = sheetIndex < all.count ? all[sheetIndex] : []
        let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 4), count: layout.columns)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(slots, id: \.id) { slot in
                VStack(spacing: 3) {
                    DVImage(slot.id)
                        .font(.system(size: 18, weight: .medium))
                        .frame(height: 22)
                        .foregroundStyle(store.isImported(slot.id) ? Theme.accent : Theme.text)
                    Text(slot.title).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .padding(.vertical, 4)
    }

    private var importSection: some View {
        Section {
            Button {
                importMode = .files
                showImporter = true
            } label: { DVLabel("画像・フォルダーを取り込む（名前で入れる）", icon: "home.open") }
        } header: {
            Text("名前の付いた画像を取り込む")
        } footer: {
            Text("ChatGPT の ZIP は「ファイル」アプリでタップすると展開できます。そのフォルダーを選んでください。ファイル名は edit.split.png・edit_split.png・SF Symbols の名前（scissors.png）のどれでも分かります。")
        }
    }

    // MARK: 一覧

    private var previewSection: some View {
        Section {
            Picker("場所", selection: $group) {
                ForEach(IconGroup.allCases, id: \.self) { g in Text(g.title).tag(g) }
            }
            ForEach(IconCatalog.slots(in: group), id: \.id) { slot in
                row(slot)
            }
        } header: {
            Text("一覧（タップで 1 つずつ替える）")
        }
    }

    private func row(_ slot: IconSlot) -> some View {
        HStack(spacing: 12) {
            DVImage(slot.id)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 30, height: 26)
                .foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title).font(.footnote)
                Text(slot.fileName).font(.caption2.monospaced()).foregroundStyle(Theme.subtext)
            }
            Spacer()
            if store.isImported(slot.id) {
                DVImage("status.done").foregroundStyle(Theme.accent).font(.footnote)
            }
            Menu {
                Button {
                    copy(IconPrompt.single(slot, style: style), "「\(slot.title)」のプロンプトをコピーしました")
                } label: { Label("このアイコンのプロンプトをコピー", systemImage: "doc.on.doc") }
                Button {
                    singleTarget = slot
                    importMode = .single
                    showImporter = true
                } label: { Label("ファイルから選ぶ", systemImage: "folder") }
                Button {
                    singleTarget = slot
                    pickSinglePhoto = true
                } label: { Label("写真から選ぶ", systemImage: "photo") }
                if store.isImported(slot.id) {
                    Button(role: .destructive) { store.remove(slot.id) } label: { Label("元の絵に戻す", systemImage: "arrow.uturn.backward") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.body)
            }
        }
    }

    // MARK: 取り込み

    private func handle(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        let mode: ImportMode = importMode
        let index: Int = sheetIndex
        let chosen: IconSheetLayout = layout
        let target: IconSlot? = singleTarget
        busy = true
        Task {
            var made = IconImportReport()
            switch mode {
            case .files:
                made = await store.importFiles(urls)
            case .sheet, .single:
                let url: URL = urls[0]
                let access: Bool = url.startAccessingSecurityScopedResource()
                let data: Data? = try? Data(contentsOf: url)
                if access { url.stopAccessingSecurityScopedResource() }
                if let bytes = data {
                    if mode == .sheet {
                        made = await store.importSheet(bytes, index: index, layout: chosen)
                    } else if let slot = target {
                        made = await store.importSingle(bytes, id: slot.id)
                    }
                } else {
                    made.failed.append(url.lastPathComponent)
                }
            }
            busy = false
            report = made
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?, forSheet: Bool) {
        guard let picked = item else { return }
        let index: Int = sheetIndex
        let chosen: IconSheetLayout = layout
        let target: IconSlot? = singleTarget
        busy = true
        Task {
            var made = IconImportReport()
            if let data = try? await picked.loadTransferable(type: Data.self) {
                if forSheet {
                    made = await store.importSheet(data, index: index, layout: chosen)
                } else if let slot = target {
                    made = await store.importSingle(data, id: slot.id)
                }
            } else {
                made.failed.append("写真")
            }
            busy = false
            report = made
            if forSheet { sheetPhoto = nil } else { singlePhoto = nil }
        }
    }

    private func copy(_ text: String, _ note: String) {
        UIPasteboard.general.string = text
        copied = note
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if copied == note { copied = nil }
        }
    }
}
