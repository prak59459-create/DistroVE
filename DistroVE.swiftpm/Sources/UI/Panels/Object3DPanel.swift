import SwiftUI
import UniformTypeIdentifiers

/// 3D（Q50）。何も選んでいなければ追加、3D のクリップを選んでいれば中身の編集。
struct Object3DPanel: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        if let clip = controller.selectedClip, clip.kind == .object3D, let content = clip.object3D {
            Object3DEditor(controller: controller, clip: clip, content: content)
        } else {
            Object3DAddView(controller: controller)
        }
    }
}

/// 3D の追加：立体文字・基本の立体・3D モデルの読み込み。
struct Object3DAddView: View {
    @ObservedObject var controller: EditorController
    @State private var showImporter: Bool = false

    static var modelTypes: [UTType] {
        var types: [UTType] = []
        for ext in MediaFormatSupport.modelExtensions.sorted() {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { controller.addObject3D(.text) } label: { Label("3D 文字を追加", systemImage: "textformat") }
                .buttonStyle(.borderedProminent)
            PanelTitle(text: "基本の立体")
            HStack {
                ForEach(Object3DKind.primitives, id: \.self) { kind in
                    Button { controller.addObject3D(kind) } label: { Label(kind.label, systemImage: kind.symbol) }
                        .buttonStyle(.bordered)
                }
            }
            .font(.caption)
            Button { showImporter = true } label: { Label("3D モデルを読み込む（USDZ・OBJ・STL・PLY）", systemImage: "square.and.arrow.down") }
                .buttonStyle(.bordered)
            Text("位置・大きさ・回転は「変形」、動きの出入りは「アニメ」で付けられます。回転にはキーフレームも打てます。")
                .font(.caption2)
                .foregroundStyle(Theme.subtext)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Object3DAddView.modelTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                controller.importModel(url)
            }
        }
    }
}

/// 3D の中身の編集。
struct Object3DEditor: View {
    @ObservedObject var controller: EditorController
    let clip: Clip
    let content: Object3DContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if content.kind == .text {
                Object3DTextSection(controller: controller, content: content)
            } else if content.kind == .model {
                Toggle("モデルの色とテクスチャをそのまま使う", isOn: Binding<Bool>(get: { content.useModelMaterials },
                                                                   set: { v in controller.update3D("モデルの色") { $0.useModelMaterials = v } }))
                    .font(.footnote)
            }
            Object3DMaterialSection(controller: controller, content: content)
            Object3DSceneSection(controller: controller, clip: clip, content: content)
        }
    }
}

/// 文字・フォント・押し出し・面取り。
struct Object3DTextSection: View {
    @ObservedObject var controller: EditorController
    let content: Object3DContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("文字", text: Binding<String>(get: { content.text },
                                                  set: { v in controller.update3D("3D 文字", coalesce: "3d-text") { $0.text = v } }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack {
                fontMenu
                Toggle("太字", isOn: Binding<Bool>(get: { content.bold }, set: { v in controller.update3D("太字") { $0.bold = v } }))
                    .toggleStyle(.button)
            }
            .font(.footnote)
            ParamRow(label: "奥行き", range: Object3DContent.depthRange, value: content.depth,
                     onChange: { v in controller.update3D("奥行き", coalesce: "3d-depth") { $0.depth = v } })
            ParamRow(label: "面取り", range: Object3DContent.bevelRange, value: content.bevel, format: "%.3f",
                     onChange: { v in controller.update3D("面取り", coalesce: "3d-bevel") { $0.bevel = v } })
        }
    }

    private var fontMenu: some View {
        Menu {
            Button("システム（標準）") { controller.update3D("フォント") { $0.fontName = "" } }
            ForEach(TextEditorPanel.fontFamilies(), id: \.self) { family in
                Button(family) { controller.update3D("フォント") { $0.fontName = family } }
            }
        } label: {
            Label(content.fontName.isEmpty ? "システム" : content.fontName, systemImage: "textformat")
        }
    }
}

/// 材質（色・金属・つや・発光）。
struct Object3DMaterialSection: View {
    @ObservedObject var controller: EditorController
    let content: Object3DContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(text: "材質")
            presets
            colors
            sliders
        }
    }

    private var presets: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Material3D.presets, id: \.name) { preset in
                    LookChoice(title: preset.name, isSelected: content.material == preset.material) {
                        controller.update3D("材質") { $0.material = preset.material }
                    }
                }
            }
        }
        .font(.caption)
    }

    private var colors: some View {
        HStack {
            colorPicker(content.kind == .text ? "表の色" : "色", content.material.color) { $0.material.color = $1 }
            if content.kind == .text {
                colorPicker("側面の色", content.material.sideColor) { $0.material.sideColor = $1 }
            }
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 6) {
            ParamRow(label: "金属", range: 0...1, value: content.material.metallic,
                     onChange: { v in controller.update3D("金属", coalesce: "3d-metal") { $0.material.metallic = v } })
            ParamRow(label: "ざらつき", range: 0...1, value: content.material.roughness,
                     onChange: { v in controller.update3D("ざらつき", coalesce: "3d-rough") { $0.material.roughness = v } })
            ParamRow(label: "発光", range: 0...1, value: content.material.glow,
                     onChange: { v in controller.update3D("発光", coalesce: "3d-glow") { $0.material.glow = v } })
        }
    }

    private func colorPicker(_ label: String, _ value: RGBA, _ set: @escaping (inout Object3DContent, RGBA) -> Void) -> some View {
        ColorPicker(label, selection: Binding<Color>(get: { value.color }, set: { c in
            controller.update3D(label, coalesce: label) { set(&$0, RGBA(c)) }
        }))
        .font(.footnote)
    }
}

/// 照明・自動の動き・大きさ・画角・奥行き（キーフレーム可）。
struct Object3DSceneSection: View {
    @ObservedObject var controller: EditorController
    let clip: Clip
    let content: Object3DContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelTitle(text: "照明")
            ChipPicker(items: Lighting3D.allCases, selection: content.lighting, label: { $0.label }) { preset in
                controller.update3D("照明") { $0.lighting = preset }
            }
            PanelTitle(text: "自動の動き")
            ChipPicker(items: Motion3D.allCases, selection: content.motion, label: { $0.label }) { motion in
                controller.update3D("自動の動き") { $0.motion = motion }
            }
            if content.motion != .none {
                ParamRow(label: "動きの速さ", range: 0.1...4, value: content.motionSpeed,
                         onChange: { v in controller.update3D("動きの速さ", coalesce: "3d-speed") { $0.motionSpeed = v } })
            }
            PanelTitle(text: "カメラ")
            ParamRow(label: "大きさ", range: Object3DContent.sizeRange, value: content.size,
                     onChange: { v in controller.update3D("3D の大きさ", coalesce: "3d-size") { $0.size = v } })
            ParamRow(label: "画角", range: Object3DContent.fieldOfViewRange, value: content.fieldOfView, format: "%.0f°",
                     onChange: { v in controller.update3D("画角", coalesce: "3d-fov") { $0.fieldOfView = v } })
            ClipParamRow(controller: controller, clip: clip, label: "奥行きの位置", path: \.object3D!.positionZ, range: -2...1, defaultValue: 0)
        }
    }
}
