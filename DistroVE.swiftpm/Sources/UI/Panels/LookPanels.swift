import SwiftUI
import UniformTypeIdentifiers

/// 色の調整とトーンカーブ（Q41）。
struct AdjustPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(ColorSpecs.all, id: \.key) { spec in
                    let param: Param = clip.color.param(spec)
                    ParamRow(label: spec.label, range: spec.minValue...spec.maxValue, value: controller.colorValue(spec),
                             format: spec.unit == "°" ? "%.0f°" : "%.2f",
                             keyState: controller.keyState(param, clip: clip),
                             onChange: { controller.setColor(spec, $0) },
                             onToggleKey: { controller.toggleColorKey(spec) },
                             onReset: { controller.updateSelected("\(spec.label)をリセット") { $0.color.values[spec.key] = nil } })
                }
                PanelTitle(text: "トーンカーブ")
                CurveEditor(controller: controller, clip: clip)
            }
        } else {
            SelectClipHint()
        }
    }
}

/// トーンカーブの編集。黒・暗部・中間・明部・白の 5 点を上下に動かす。
struct CurveEditor: View {
    @ObservedObject var controller: EditorController
    let clip: Clip
    @State private var channel: Int = 0

    private let positions: [Double] = [0, 0.25, 0.5, 0.75, 1]

    var body: some View {
        let curves: CurveSet = clip.curves ?? CurveSet()
        let points: [Vec2] = current(curves)
        VStack(alignment: .leading, spacing: 8) {
            Picker("チャンネル", selection: $channel) {
                Text("全体").tag(0)
                Text("R").tag(1)
                Text("G").tag(2)
                Text("B").tag(3)
            }
            .pickerStyle(.segmented)
            Canvas { context, size in
                drawCurve(context, size: size, points: points)
            }
            .frame(height: 120)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
            ForEach(0..<5, id: \.self) { i in
                ParamRow(label: label(i), range: 0...1, value: value(points, at: positions[i]), onChange: { v in
                    set(i, v)
                })
            }
            HStack {
                Button("S 字（コントラスト）") { applyPreset(CurveSet.sCurve(0.08)) }
                Button("リセット") { controller.updateSelected("カーブをリセット") { $0.curves = nil } }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    private func label(_ i: Int) -> String {
        let names: [String] = ["黒", "暗部", "中間", "明部", "白"]
        return names[i]
    }

    private func current(_ curves: CurveSet) -> [Vec2] {
        switch channel {
        case 1: return curves.red
        case 2: return curves.green
        case 3: return curves.blue
        default: return curves.master
        }
    }

    private func value(_ points: [Vec2], at x: Double) -> Double {
        let table: [Float] = ToneCurve.table(points, count: 101)
        return Double(table[Int((x * 100).rounded())])
    }

    private func set(_ index: Int, _ v: Double) {
        let channelIndex: Int = channel
        let xs: [Double] = positions
        controller.updateSelected("トーンカーブ", coalesce: "curve-\(channelIndex)-\(index)") { c in
            var curves: CurveSet = c.curves ?? CurveSet()
            var points: [Vec2] = []
            let source: [Vec2]
            switch channelIndex {
            case 1: source = curves.red
            case 2: source = curves.green
            case 3: source = curves.blue
            default: source = curves.master
            }
            let table: [Float] = ToneCurve.table(source, count: 101)
            for (i, x) in xs.enumerated() {
                let y: Double = i == index ? v : Double(table[Int((x * 100).rounded())])
                points.append(Vec2(x, y))
            }
            switch channelIndex {
            case 1: curves.red = points
            case 2: curves.green = points
            case 3: curves.blue = points
            default: curves.master = points
            }
            c.curves = curves
        }
    }

    private func applyPreset(_ preset: CurveSet) {
        controller.updateSelected("トーンカーブ") { $0.curves = preset }
    }

    private func drawCurve(_ context: GraphicsContext, size: CGSize, points: [Vec2]) {
        var grid = Path()
        for i in 1..<4 {
            let x: CGFloat = size.width * CGFloat(i) / 4
            let y: CGFloat = size.height * CGFloat(i) / 4
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(Theme.line), lineWidth: 0.5)
        let table: [Float] = ToneCurve.table(points, count: 64)
        var path = Path()
        for (i, v) in table.enumerated() {
            let x: CGFloat = size.width * CGFloat(i) / 63
            let y: CGFloat = size.height * (1 - CGFloat(v))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        let colors: [Color] = [Theme.text, .red, .green, .blue]
        context.stroke(path, with: .color(colors[channel]), lineWidth: 2)
    }
}

/// フィルター（内蔵の色味・読み込んだ LUT・GitHub から受け取った LUT）（Q41）。
struct FiltersPanel: View {
    @ObservedObject var controller: EditorController
    @State private var showImporter: Bool = false
    @State private var imported: [(UUID, String)] = LUTLibrary.list()

    var body: some View {
        if let clip = controller.selectedClip {
            content(clip)
                .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                    importLUTs(result)
                }
        } else {
            SelectClipHint()
        }
    }

    private func content(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            builtinGrid(clip)
            if !imported.isEmpty {
                PanelTitle(text: "読み込んだ LUT")
                importedList(clip)
            }
            if let look = clip.look {
                ParamRow(label: "強さ", range: 0...1, value: look.intensity, onChange: { v in
                    controller.updateSelected("フィルターの強さ", coalesce: "look-intensity") { $0.look?.intensity = v }
                })
            }
            Button {
                showImporter = true
            } label: {
                DVLabel("LUT（.cube）を読み込む", icon: "export.lut")
            }
            .buttonStyle(.bordered)
            .font(.footnote)
        }
    }

    private func builtinGrid(_ clip: Clip) -> some View {
        let columns: [GridItem] = Array(repeating: GridItem(.flexible()), count: 4)
        let current: String? = clip.look?.id
        return LazyVGrid(columns: columns, spacing: 8) {
            LookChoice(title: "なし", isSelected: current == nil) {
                controller.updateSelected("フィルター") { $0.look = nil }
            }
            ForEach(BuiltinLooks.all) { look in
                let id: String = "builtin:" + look.id
                LookChoice(title: look.label, isSelected: current == id) { select(id, clip: clip) }
            }
        }
        .font(.caption)
    }

    private func importedList(_ clip: Clip) -> some View {
        let current: String? = clip.look?.id
        return ForEach(imported, id: \.0) { item in
            let id: String = "lut:" + item.0.uuidString
            LookChoice(title: item.1, isSelected: current == id) { select(id, clip: clip) }
                .font(.caption)
        }
    }

    private func importLUTs(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls { importLUT(url) }
        imported = LUTLibrary.list()
    }

    private func select(_ id: String, clip: Clip) {
        let intensity: Double = clip.look?.intensity ?? 1
        controller.updateSelected("フィルター") { $0.look = LookSettings(id: id, intensity: intensity) }
    }

    private func importLUT(_ url: URL) {
        do {
            try LUTLibrary.importFile(url)
        } catch {
            controller.alert = EditorAlert(title: "LUT を読み込めません", message: error.localizedDescription)
        }
    }
}

/// フィルターの選択肢 1 つ（選んでいるものは強調色）。
struct LookChoice: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .tint(isSelected ? Theme.accent : nil)
    }
}

/// 読み込んだ LUT の置き場所（Support/LUTs/<UUID>.cube と名前の一覧）。GitHub から受け取った LUT もここに並べる。
enum LUTLibrary {
    private static var indexURL: URL {
        return ColorPipeline.lutFolder.appendingPathComponent("index.json")
    }

    static func list() -> [(UUID, String)] {
        var result: [(UUID, String)] = []
        if let data = try? Data(contentsOf: indexURL), let names = try? JSONDecoder().decode([String: String].self, from: data) {
            for (key, name) in names {
                if let id = UUID(uuidString: key) { result.append((id, name)) }
            }
        }
        result.sort { $0.1 < $1.1 }
        return result
    }

    static func importFile(_ url: URL) throws {
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text: String = try String(contentsOf: url, encoding: .utf8)
        let lut: CubeLUT = try CubeLUT.parse(text)
        let id = UUID()
        try text.write(to: ColorPipeline.lutFolder.appendingPathComponent(id.uuidString + ".cube"), atomically: true, encoding: .utf8)
        var names: [String: String] = [:]
        if let data = try? Data(contentsOf: indexURL), let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            names = decoded
        }
        let title: String = lut.title == "LUT" ? url.deletingPathExtension().lastPathComponent : lut.title
        names[id.uuidString] = title
        let data: Data = try JSONEncoder().encode(names)
        try data.write(to: indexURL, options: .atomic)
        FrameRenderer.shared.colors.registerImported(id, lut: lut)
    }

    /// GitHub から受け取った LUT を一覧に加える（同じ名前はとばす）。
    static func syncDownloaded() {
        let existing = Set<String>(list().map { $0.1 })
        for url in ContentUpdater.installedLUTs() {
            let name: String = url.deletingPathExtension().lastPathComponent
            if existing.contains(name) { continue }
            try? importFile(url)
        }
    }
}

/// エフェクト（Q42）。ビートに合わせて脈打たせることもできる。
struct EffectsPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(clip.effects) { effect in
                    EffectEditor(controller: controller, clip: clip, effect: effect)
                }
                PanelTitle(text: "追加")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                    ForEach(EffectKind.allCases, id: \.self) { kind in
                        IconChoiceButton(title: kind.label, icon: kind.iconID) {
                            controller.updateSelected("エフェクトを追加") { c in
                                var effect = VideoEffect(kind: kind)
                                effect.beatSync = kind.supportsBeatSync && !controller.project.beatTimes.isEmpty
                                c.effects.append(effect)
                            }
                        }
                    }
                }
                if controller.project.beatTimes.isEmpty {
                    Text("ビートマーカーを作ると（音声クリップの「ビート検出」）、シェイクやフラッシュを拍に合わせられます。")
                        .font(.caption)
                        .foregroundStyle(Theme.subtext)
                }
            }
        } else {
            SelectClipHint()
        }
    }
}

struct EffectEditor: View {
    @ObservedObject var controller: EditorController
    let clip: Clip
    let effect: VideoEffect

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                DVImage(effect.kind.iconID)
                Text(effect.kind.label).font(.footnote.weight(.semibold))
                Spacer()
                if effect.kind.supportsBeatSync {
                    Toggle("ビート同期", isOn: Binding<Bool>(get: { effect.beatSync }, set: { v in update { $0.beatSync = v } }))
                        .font(.caption)
                        .fixedSize()
                }
                Toggle("", isOn: Binding<Bool>(get: { effect.isEnabled }, set: { v in update { $0.isEnabled = v } }))
                    .labelsHidden()
                Button {
                    let id: UUID = effect.id
                    controller.updateSelected("エフェクトを削除") { $0.effects.removeAll { $0.id == id } }
                } label: {
                    DVImage("effect.remove")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("エフェクトを外す")
            }
            ForEach(effect.kind.specs, id: \.key) { spec in
                let param: Param = effect.params.param(spec)
                ParamRow(label: spec.label, range: spec.minValue...spec.maxValue,
                         value: param.value(at: controller.localTime(of: clip)),
                         keyState: controller.keyState(param, clip: clip),
                         onChange: { controller.setEffectParam(effect.id, spec, $0) },
                         onToggleKey: { controller.toggleEffectKey(effect.id, spec) })
            }
        }
        .padding(10)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
    }

    private func update(_ change: @escaping (inout VideoEffect) -> Void) {
        let id: UUID = effect.id
        controller.updateSelected("エフェクトの設定") { c in
            if let i = c.effects.firstIndex(where: { $0.id == id }) { change(&c.effects[i]) }
        }
    }
}
