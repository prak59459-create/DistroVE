import SwiftUI
import UniformTypeIdentifiers

/// 設定（Q63, Q64, Q69, Q70, Q79, Q84, Q86, Q88, Q89）。
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var cacheSize: Int64 = CacheManager.cacheSize()
    @State private var message: String?
    @State private var showFolderPicker: Bool = false
    @State private var syncFolder: String? = ProjectStore.shared.syncFolderName
    @State private var usageConsent: Bool = Diagnostics.shared.usageConsent
    @State private var contentAutoCheck: Bool = ContentUpdater.shared.autoCheck
    @State private var updating: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                displaySection
                editingSection
                mediaSection
                Section("キーボードショートカット") {
                    NavigationLink("割り当てを変える") { ShortcutEditor() }
                }
                syncSection
                storageSection
                privacySection
                contentSection
                aboutSection
                if let message = message {
                    Text(message).font(.footnote).foregroundStyle(Theme.accent)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } }
            }
            .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                chooseFolder(result)
            }
        }
    }

    private var displaySection: some View {
        Section("画面") {
            Picker("テーマ", selection: $settings.theme) {
                ForEach(AppSettings.Theme.allCases) { t in Text(t.label).tag(t) }
            }
            Picker("文字の大きさ", selection: $settings.textSize) {
                ForEach(AppSettings.TextSize.allCases) { t in Text(t.label).tag(t) }
            }
            Toggle("色覚に配慮した配色", isOn: $settings.colorBlindPalette)
            Picker("パネルの位置（横向き）", selection: $settings.inspectorPosition) {
                ForEach(AppSettings.InspectorPosition.allCases) { p in Text(p.label).tag(p) }
            }
            Toggle("ツールバーを上に置く", isOn: $settings.toolbarAtTop)
            Toggle("スナップ（吸着）", isOn: $settings.snapping)
        }
    }

    /// 編集の経験（Q15）・端末の性能（Q81）・ツールバー（Q70）。
    private var editingSection: some View {
        Section("編集の経験・端末の性能") {
            Picker("編集の経験", selection: $settings.editorLevel) {
                ForEach(EditorLevel.allCases, id: \.self) { level in Text(level.label).tag(level) }
            }
            Text(settings.editorLevel.detail).font(.caption).foregroundStyle(Theme.subtext)
            Picker("端末の性能", selection: $settings.deviceTier) {
                Text("自動（この端末は「" + DevicePerformance.detected.label + "」）").tag(DeviceTier?.none)
                ForEach(DeviceTier.allCases, id: \.self) { tier in Text(tier.label).tag(DeviceTier?.some(tier)) }
            }
            Text(DevicePerformance.current.detail).font(.caption).foregroundStyle(Theme.subtext)
            NavigationLink("ツールバーの道具の並び・表示") { ToolbarEditor() }
        }
    }

    private var mediaSection: some View {
        Section("素材") {
            Toggle("取り込むときにコピーする（オフで参照のみ）", isOn: $settings.copyMediaOnImport)
            Toggle("重い素材は自動でプロキシを作る", isOn: $settings.autoProxy)
        }
    }

    private var syncSection: some View {
        Section("同期・バックアップ") {
            Text(syncFolder.map { "同期先：\($0)" } ?? "同期先が未設定です（iCloud Drive などのフォルダーを選べます）")
                .font(.footnote)
            Button("同期先のフォルダーを選ぶ") { showFolderPicker = true }
            if syncFolder != nil {
                Button("今すぐ同期") { sync() }
                Button("同期をやめる", role: .destructive) {
                    try? ProjectStore.shared.setSyncFolder(nil)
                    syncFolder = nil
                }
            }
            Text("プロジェクトは自動保存し、手動保存と 5 分ごとにバックアップを残します（最大 20 世代）。")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
        }
    }

    private var storageSection: some View {
        Section("容量") {
            LabeledContent("キャッシュ", value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
            Button("キャッシュを削除") {
                CacheManager.clearAll()
                cacheSize = CacheManager.cacheSize()
                message = "キャッシュを削除しました"
            }
            Button("使っていない素材ファイルを削除") {
                let freed: Int64 = ProjectStore.shared.cleanUnusedMedia()
                message = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file) + " 空きました"
            }
        }
    }

    private var privacySection: some View {
        Section("AI とプライバシー") {
            Toggle("端末内で文字起こしできないとき、音声だけ Apple のサーバーに送ってよい", isOn: $settings.allowServerSpeech)
            Toggle("機能の使用回数を端末内に記録する（同意）", isOn: $usageConsent)
                .onChange(of: usageConsent) { _, value in Diagnostics.shared.usageConsent = value }
            NavigationLink("記録とクラッシュログを見る") { DiagnosticsView() }
            NavigationLink("プライバシーポリシー") { PrivacyPolicyView() }
        }
    }

    private var contentSection: some View {
        Section("追加のテンプレート・LUT（GitHub から受け取る）") {
            Toggle("起動時に確認する", isOn: $contentAutoCheck)
                .onChange(of: contentAutoCheck) { _, value in ContentUpdater.shared.autoCheck = value }
            Button(updating ? "確認中…" : "今すぐ確認") { checkContent() }
                .disabled(updating)
            Text("受け取るのはテンプレートと LUT のデータだけで、アプリのプログラムは変わりません。次回の起動で反映されます。")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
        }
    }

    private var aboutSection: some View {
        Section("このアプリについて") {
            LabeledContent("バージョン", value: ContentUpdater.appVersion)
            LabeledContent("端末の温度", value: DeviceCapability.thermalLabel)
            Text("Distro VE は無料・端末内処理の動画編集アプリです。書き出した動画に透かしは入りません。")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
            Button("チュートリアルをもう一度見る") {
                settings.hasSeenTutorial = false
                dismiss()
            }
        }
    }

    private func chooseFolder(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            try ProjectStore.shared.setSyncFolder(url)
            syncFolder = ProjectStore.shared.syncFolderName
        } catch {
            message = error.localizedDescription
        }
    }

    private func sync() {
        do {
            let result: ProjectStore.SyncResult = try ProjectStore.shared.sync()
            message = "送信 \(result.uploaded) 件・受信 \(result.downloaded) 件・素材 \(result.mediaCopied) 件"
        } catch {
            message = error.localizedDescription
        }
    }

    private func checkContent() {
        updating = true
        Task {
            do {
                let count: Int = try await ContentUpdater.shared.update()
                message = count == 0 ? "最新です" : "\(count) 件を受け取りました。次回の起動で反映されます。"
            } catch {
                message = "確認できませんでした：" + error.localizedDescription
            }
            updating = false
        }
    }
}

/// キーボードショートカットの変更（Q70）。
struct ShortcutEditor: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            ForEach(ShortcutAction.allCases) { action in
                HStack {
                    Text(action.label)
                    Spacer()
                    if action.isCustomizable {
                        TextField("キー", text: binding(action))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .textInputAutocapitalization(.never)
                    } else {
                        Text(settings.shortcuts[action.rawValue] ?? "").foregroundStyle(Theme.subtext)
                    }
                }
            }
            Button("初期設定に戻す") { settings.shortcuts = ShortcutAction.defaults }
            Text("1 文字のキー、または space・delete・left・right を入れてください。")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
        }
        .navigationTitle("ショートカット")
    }

    private func binding(_ action: ShortcutAction) -> Binding<String> {
        return Binding<String>(get: { settings.shortcuts[action.rawValue] ?? "" }, set: { value in
            let trimmed: String = value.trimmingCharacters(in: .whitespaces).lowercased()
            let allowed: Set<String> = ["space", "delete", "left", "right"]
            if trimmed.count == 1 || allowed.contains(trimmed) {
                settings.shortcuts[action.rawValue] = trimmed
            }
        })
    }
}

/// 端末内の記録の確認と共有（Q86, Q89）。
struct DiagnosticsView: View {
    @State private var usage: [(String, Int)] = Diagnostics.shared.usageSummary()

    var body: some View {
        List {
            Section("クラッシュログ・動作ログ") {
                let files: [URL] = Diagnostics.shared.reportFiles()
                if files.isEmpty {
                    Text("記録はありません").foregroundStyle(Theme.subtext)
                }
                ForEach(files, id: \.self) { url in
                    ShareLink(item: url) {
                        Label(url.lastPathComponent, systemImage: url.lastPathComponent.hasPrefix("crash") ? "exclamationmark.triangle" : "doc.text")
                    }
                }
                Text("ログは端末の外へ自動では送りません。不具合を知らせるときに、ここから共有できます。")
                    .font(.caption)
                    .foregroundStyle(Theme.subtext)
            }
            Section("機能の使用回数（同意したときだけ記録）") {
                ForEach(usage, id: \.0) { item in
                    LabeledContent(item.0, value: "\(item.1)")
                }
                Button("記録を消す", role: .destructive) {
                    Diagnostics.shared.clearUsage()
                    usage = []
                }
            }
        }
        .navigationTitle("記録")
    }
}

/// プライバシーポリシー（Q88）。
struct PrivacyPolicyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("プライバシーポリシー").font(.title2.weight(.bold))
                policy("動画・写真・音声", "取り込んだ素材と編集内容は、この端末の中だけで処理・保存します。開発者のサーバーへは送りません。")
                policy("AI の処理", "自動字幕・背景除去・無音カット・ビート検出・手ぶれ補正・ハイライト抽出・翻訳は端末内で行います。端末が日本語の端末内文字起こしに対応していない場合に限り、利用者が許可したときだけ、音声を Apple の音声認識サーバーに送ります（Apple のプライバシーポリシーが適用されます）。")
                policy("同期", "同期を設定した場合、プロジェクトと素材を利用者が選んだフォルダー（iCloud Drive など）にコピーします。")
                policy("利用状況", "同意した場合に限り、機能の使用回数を端末内に記録します。外部へは送りません。")
                policy("クラッシュログ", "アプリが異常終了したときの記録を端末内に保存します。利用者が共有を選んだときだけ外部に出ます。")
                policy("追加データの取得", "追加テンプレート・LUT の確認のとき、GitHub（raw.githubusercontent.com）に接続します。個人を特定する情報は送りません。")
                policy("広告", "現在、広告は表示していません。導入する場合は、配信元が集める情報をこのページに追記し、事前に同意を求めます。")
            }
            .padding(20)
        }
        .navigationTitle("プライバシー")
    }

    private func policy(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body).font(.callout).foregroundStyle(Theme.subtext)
        }
    }
}

/// 初回のチュートリアル（Q65）。
/// ツールバーの道具の並べ替えと表示の切り替え（Q70）。
struct ToolbarEditor: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        List {
            Section {
                ForEach(RootTool.ordered(settings.rootToolOrder)) { tool in
                    Toggle(isOn: binding(for: tool)) { Label(tool.title, systemImage: tool.symbol) }
                }
                .onMove { from, to in move(from, to) }
            } footer: {
                Text("右のつまみで並べ替えます。オフにした道具はツールバーに出ません。「かんたん」では一部の道具を自動で隠します。")
            }
            Button("最初の並びに戻す") {
                settings.rootToolOrder = RootTool.allCases.map { $0.rawValue }
                settings.hiddenRootTools = []
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("ツールバー")
    }

    private func binding(for tool: RootTool) -> Binding<Bool> {
        return Binding<Bool>(get: { !settings.hiddenRootTools.contains(tool.rawValue) }, set: { on in
            var hidden: [String] = settings.hiddenRootTools.filter { $0 != tool.rawValue }
            if !on { hidden.append(tool.rawValue) }
            settings.hiddenRootTools = hidden
        })
    }

    private func move(_ from: IndexSet, _ to: Int) {
        var order: [String] = RootTool.ordered(settings.rootToolOrder).map { $0.rawValue }
        order.move(fromOffsets: from, toOffset: to)
        settings.rootToolOrder = order
    }
}

struct TutorialView: View {
    let onDone: () -> Void
    @EnvironmentObject private var settings: AppSettings
    @State private var page: Int = 0

    private let pages: [(String, String, String)] = [
        ("film.stack", "Distro VE へようこそ", "無料・端末内処理の動画編集アプリです。編集はオフラインで完結し、動画を外に送りません。"),
        ("plus.rectangle.on.rectangle", "素材を追加", "「新規プロジェクト」を作り、下の「素材」から写真ライブラリやファイルの動画・画像を入れます。ドラッグ＆ドロップもできます。"),
        ("hand.draw", "タイムラインの操作", "指 1 本で左右にスクロール、ピンチで拡大縮小、2 本指でゆっくり精密に動かせます。クリップは長押しで移動、選んで端をつまむと長さを変えられます。"),
        ("diamond", "キーフレームとエフェクト", "パラメーターの ◆ を押すと、その時刻の値を記録します。色・位置・大きさ・音量などすべて動かせます。"),
        ("wand.and.stars", "AI と自動編集", "自動字幕・無音カット・BGM に合わせた自動編集・ショート変換・背景除去が端末内で使えます。"),
        ("square.and.arrow.up", "書き出し", "YouTube・TikTok・Instagram のプリセットで、透かしなしの MP4 や GIF を保存できます。")
    ]

    /// 編集の経験（Q15）。初心者からプロまで、出す道具の数を変える。
    private var levelChooser: some View {
        VStack(spacing: 6) {
            Picker("編集の経験", selection: $settings.editorLevel) {
                ForEach(EditorLevel.allCases, id: \.self) { level in Text(level.label).tag(level) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            Text(settings.editorLevel.detail + "（あとで設定から変えられます）")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.subtext)
                .frame(maxWidth: 520)
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { i in
                    VStack(spacing: 18) {
                        Image(systemName: pages[i].0)
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.accent)
                        Text(pages[i].1).font(.title.weight(.bold))
                        Text(pages[i].2)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.subtext)
                            .frame(maxWidth: 520)
                    }
                    .padding(30)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            levelChooser
            HStack {
                Button("スキップ") { onDone() }
                Spacer()
                Button(page == pages.count - 1 ? "はじめる" : "次へ") {
                    if page == pages.count - 1 {
                        onDone()
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
        }
        .background(Theme.background.ignoresSafeArea())
    }
}

/// よくある質問（Q97）。
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let items: [(String, String)] = [
        ("MKV・WebM・AVI が読み込めません", "iPad の標準の仕組みでは読めない形式です。MP4 か MOV に変換してから取り込んでください。"),
        ("プレビューがカクカクします", "再生ボタン横の画質メニューで「1/2」や「1/4」、または「プロキシで再生」を選ぶと軽くなります。端末が熱いときは自動で軽くします。"),
        ("元に戻すは何回までできますか", "回数の制限はありません。古い履歴は端末に保存して、メモリを使いすぎないようにしています。"),
        ("アプリが落ちたら作業は消えますか", "編集は 1.5 秒ごとに自動保存しています。次に開いたときに続きから編集できます。バックアップの世代からも戻せます。"),
        ("4K や 120fps が選べません", "端末の性能が足りない場合は選べないようにしています。"),
        ("BGM の著作権は？", "同梱の BGM・効果音はアプリ内で合成した音源なので、自由に使えます。ほかの曲を使うときは権利を確認してください。"),
        ("ほかの iPad にプロジェクトを移すには", "ホームでプロジェクトを長押しし、「.disve を共有」で送るか、設定の「同期」で iCloud Drive などのフォルダーを使います。"),
        ("ショートカットを変えたい", "設定の「キーボードショートカット」で変更できます。")
    ]

    var body: some View {
        NavigationStack {
            List {
                ForEach(items, id: \.0) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.0).font(.subheadline.weight(.semibold))
                        Text(item.1).font(.footnote).foregroundStyle(Theme.subtext)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("よくある質問")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}
