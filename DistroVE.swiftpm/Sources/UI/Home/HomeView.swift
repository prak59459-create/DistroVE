import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 入口。ホーム（プロジェクト一覧）と編集画面を切り替え、初回はチュートリアルを出す（Q65）。
struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var openProject: Project?
    @State private var showTutorial: Bool = false
    @State private var interrupted: UUID? = ProjectStore.shared.interruptedProject()

    var body: some View {
        Group {
            if let project = openProject {
                EditorView(project: project) {
                    openProject = nil
                }
                .id(project.id)
            } else {
                HomeView(interrupted: $interrupted) { project in
                    openProject = project
                }
            }
        }
        .onAppear {
            if !settings.hasSeenTutorial { showTutorial = true }
            LUTLibrary.syncDownloaded()
        }
        .fullScreenCover(isPresented: $showTutorial) {
            TutorialView {
                settings.hasSeenTutorial = true
                showTutorial = false
            }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @Binding var interrupted: UUID?
    let onOpen: (Project) -> Void

    @State private var projects: [ProjectStore.Summary] = []
    @State private var showNew: Bool = false
    @State private var showTemplates: Bool = false
    @State private var showSettings: Bool = false
    @State private var showHelp: Bool = false
    @State private var showImport: Bool = false
    @State private var errorMessage: String?
    @State private var renameTarget: ProjectStore.Summary?
    @State private var renameText: String = ""
    @State private var backupTarget: ProjectStore.Summary?

    private let columns: [GridItem] = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        withDialogs(withSheets(mainStack))
    }

    private var mainStack: some View {
        NavigationStack {
            ScrollView {
                projectList
                    .padding(20)
            }
            .background(BrandBackdrop())
            .navigationTitle("Distro VE")
            .toolbar { toolbarItems }
        }
        .onAppear { reload() }
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 18) {
            BrandLogo()
            if let id = interrupted, let summary = projects.first(where: { $0.id == id }) {
                recoveryBanner(summary)
            }
            HStack(spacing: 12) {
                bigButton("新規プロジェクト", "home.new", primary: true) { showNew = true }
                bigButton("テンプレート", "home.templates") { showTemplates = true }
                bigButton(".disve を開く", "home.open") { showImport = true }
            }
            Text("プロジェクト").font(.title3.weight(.bold)).foregroundStyle(Theme.text)
            if projects.isEmpty {
                VStack(spacing: 12) {
                    DVImage("illustration.empty")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("まだプロジェクトがありません。「新規プロジェクト」か「テンプレート」から始めましょう。")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.subtext)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(projects) { summary in
                    ProjectCard(summary: summary)
                        .onTapGesture { open(summary.id) }
                        .contextMenu { menu(summary) }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showHelp = true } label: { DVImage("home.help") }
                .accessibilityLabel("ヘルプ")
            Button { showSettings = true } label: { DVImage("home.settings") }
                .accessibilityLabel("設定")
        }
    }

    private func withSheets<V: View>(_ view: V) -> some View {
        view
            .sheet(isPresented: $showNew) {
                NewProjectSheet { project in
                    showNew = false
                    save(project)
                    onOpen(project)
                }
            }
            .sheet(isPresented: $showTemplates) {
                TemplateGallery { project in
                    showTemplates = false
                    save(project)
                    onOpen(project)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: reload) {
                SettingsView()
            }
            .sheet(isPresented: $showHelp) {
                HelpView()
            }
            .sheet(item: $backupTarget) { summary in
                BackupList(summary: summary) { project in
                    backupTarget = nil
                    reload()
                    onOpen(project)
                }
            }
    }

    private func withDialogs<V: View>(_ view: V) -> some View {
        view
            .fileImporter(isPresented: $showImport, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                importProject(result)
            }
            .alert("開けませんでした", isPresented: Binding<Bool>(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("名前の変更", isPresented: Binding<Bool>(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("名前", text: $renameText)
                Button("変更") { rename() }
                Button("キャンセル", role: .cancel) { renameTarget = nil }
            }
    }

    private func importProject(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            let project: Project = try ProjectStore.shared.importProject(from: url)
            reload()
            onOpen(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        projects = ProjectStore.shared.list()
    }

    private func save(_ project: Project) {
        do {
            try ProjectStore.shared.save(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func open(_ id: UUID) {
        do {
            let project: Project = try ProjectStore.shared.load(id)
            interrupted = nil
            onOpen(project)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rename() {
        guard let target = renameTarget, var project = try? ProjectStore.shared.load(target.id) else { return }
        let name: String = renameText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            project.name = name
            project.modifiedAt = Date()
            save(project)
        }
        renameTarget = nil
        reload()
    }

    @ViewBuilder
    private func menu(_ summary: ProjectStore.Summary) -> some View {
        Button { open(summary.id) } label: { DVMenuLabel("開く", icon: "project.open") }
        Button {
            renameText = summary.name
            renameTarget = summary
        } label: { DVMenuLabel("名前の変更", icon: "project.rename") }
        Button {
            _ = try? ProjectStore.shared.duplicate(summary.id)
            reload()
        } label: { DVMenuLabel("複製", icon: "project.duplicate") }
        ShareLink(item: ProjectStore.shared.fileURL(summary.id)) {
            DVMenuLabel(".disve を共有", icon: "project.share")
        }
        Button { backupTarget = summary } label: { DVMenuLabel("バックアップから戻す", icon: "project.restore") }
        Button(role: .destructive) {
            ProjectStore.shared.delete(summary.id)
            reload()
        } label: { DVMenuLabel("削除", icon: "project.delete") }
    }

    private func recoveryBanner(_ summary: ProjectStore.Summary) -> some View {
        HStack {
            DVImage("project.recovered")
            VStack(alignment: .leading) {
                Text("前回は編集中に終了しました").font(.footnote.weight(.semibold))
                Text("「\(summary.name)」は自動保存されています。続きから編集できます。").font(.caption)
            }
            Spacer()
            Button("開く") { open(summary.id) }
                .buttonStyle(.borderedProminent)
            Button("閉じる") {
                interrupted = nil
                ProjectStore.shared.markClosed()
            }
        }
        .padding(12)
        .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }

    private func bigButton(_ title: String, _ symbol: String, primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                DVImage(symbol).font(.title2)
                Text(title).font(.footnote.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .foregroundStyle(primary ? Color.black : Theme.text)
            .background(primary ? Theme.accent : Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct ProjectCard: View {
    let summary: ProjectStore.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Theme.raised
                if let url = summary.thumbnail, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    DVImage("project.placeholder").font(.largeTitle).foregroundStyle(Theme.subtext)
                }
            }
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(summary.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Text("\(summary.aspect.label) ・ \(summary.duration.shortLabel) ・ \(summary.clipCount) クリップ")
                .font(.caption)
                .foregroundStyle(Theme.subtext)
            Text(summary.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(Theme.subtext)
        }
        .padding(10)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

/// 新しいプロジェクト（縦横比・フレームレート）。
struct NewProjectSheet: View {
    let onCreate: (Project) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = "新しいプロジェクト"
    @State private var aspect: AspectPreset = .portrait9x16
    @State private var fps: Double = 30
    @State private var shortSide: Int = 1080

    var body: some View {
        NavigationStack {
            Form {
                TextField("名前", text: $name)
                Section("縦横比") {
                    Picker("縦横比", selection: $aspect) {
                        ForEach(AspectPreset.allCases, id: \.self) { a in Text(a.label).tag(a) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("画質") {
                    Picker("短い辺", selection: $shortSide) {
                        Text("720").tag(720)
                        Text("1080").tag(1080)
                        Text("1440").tag(1440)
                        Text("2160（4K）").tag(2160)
                    }
                    .pickerStyle(.segmented)
                    Picker("フレームレート", selection: $fps) {
                        Text("24").tag(24.0)
                        Text("30").tag(30.0)
                        Text("60").tag(60.0)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("新規プロジェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成") {
                        let canvas = CanvasSettings(aspect: aspect, shortSide: shortSide, fps: fps)
                        onCreate(Project(name: name.isEmpty ? "新しいプロジェクト" : name, canvas: canvas))
                    }
                }
            }
        }
    }
}

/// テンプレートから作る（Q48）。素材を選ぶと、BGM のビートに合わせて自動で並べる。
struct TemplateGallery: View {
    let onCreate: (Project) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var templates: [TemplateDefinition] = TemplateLibrary.builtin() + ContentUpdater.installedTemplates()
    @State private var selected: TemplateDefinition?
    @State private var items: [PhotosPickerItem] = []
    @State private var working: Bool = false
    @State private var status: String = ""

    var body: some View {
        NavigationStack {
            templateList
                .safeAreaInset(edge: .bottom) {
                    bottomBar
                }
                .navigationTitle("テンプレート")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                }
                .onChange(of: items) { _, picked in
                    buildIfReady(picked)
                }
        }
    }

    private var templateList: some View {
        List {
            ForEach(templates) { template in
                TemplateRow(template: template, isSelected: selected?.id == template.id) {
                    selected = template
                }
            }
        }
    }

    /// 素材を選び終えたら、選んでいるテンプレートで作る。
    private func buildIfReady(_ picked: [PhotosPickerItem]) {
        guard let template = selected, !picked.isEmpty else { return }
        build(template, items: picked)
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if working {
                ProgressView(status)
            } else if let template = selected {
                PhotosPicker(selection: $items, maxSelectionCount: 30, matching: .any(of: [.videos, .images])) {
                    DVLabel("素材を選んで作る（おすすめ \(template.slots) 個）", icon: "media.photos")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("素材なしで作る") { build(template, items: []) }
                    .buttonStyle(.bordered)
            } else {
                Text("テンプレートを選んでください").font(.footnote).foregroundStyle(Theme.subtext)
            }
        }
        .padding()
        .background(.bar)
    }

    private func build(_ template: TemplateDefinition, items: [PhotosPickerItem]) {
        working = true
        status = "素材を取り込んでいます…"
        Task {
            var media: [MediaAsset] = []
            for item in items {
                if let asset = try? await PhotoImport.load(item) { media.append(asset) }
            }
            var music: MediaAsset?
            var beats: [Time] = []
            if let id = template.music {
                status = "BGM を準備しています…"
                if let asset = try? await SoundLibraryStore.importSound(id) {
                    music = asset
                    if let url = MediaStore.shared.url(for: asset), let features = try? await AudioAnalyzer.features(for: asset, url: url),
                       let analysis = BeatDetector.analyze(features) {
                        for b in analysis.beats { beats.append(Time(seconds: b)) }
                    }
                }
            }
            let project: Project = TemplateLibrary.makeProject(template, media: media, music: music, beats: beats)
            working = false
            onCreate(project)
        }
    }
}

struct TemplateRow: View {
    let template: TemplateDefinition
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                DVImage(template.aspect == .portrait9x16 ? "template.portrait" : "template.landscape")
                    .font(.title2)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(template.name).font(.subheadline.weight(.semibold))
                    Text(template.category + " ・ " + template.aspect.label).font(.caption).foregroundStyle(Theme.subtext)
                    Text(template.summary).font(.caption).foregroundStyle(Theme.subtext)
                }
                Spacer()
                if isSelected {
                    DVImage("template.selected").foregroundStyle(Theme.accent)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// バックアップの世代から戻す（Q79）。
struct BackupList: View {
    let summary: ProjectStore.Summary
    let onRestore: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(ProjectStore.shared.backups(summary.id), id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        if let project = try? ProjectStore.shared.restore(backup: url) { onRestore(project) }
                    }
                }
            }
            .overlay {
                if ProjectStore.shared.backups(summary.id).isEmpty {
                    Text("バックアップはまだありません（手動保存や 5 分ごとの編集で作られます）。")
                        .font(.footnote)
                        .foregroundStyle(Theme.subtext)
                        .padding()
                }
            }
            .navigationTitle("「\(summary.name)」のバックアップ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
            }
        }
    }
}
