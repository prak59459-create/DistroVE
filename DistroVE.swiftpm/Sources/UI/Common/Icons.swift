import ImageIO
import SwiftUI
import UIKit

/// 取り込んだ絵 1 つ。
struct StoredIcon {
    let image: UIImage
    /// 色付き（そのまま出す）か、単色（文字の色で塗る）か
    let isColor: Bool
}

/// 取り込みの結果。
struct IconImportReport: Equatable, Sendable {
    var imported: [String] = []
    var unknown: [String] = []
    var failed: [String] = []

    var summary: String {
        var parts: [String] = ["\(imported.count) 個のアイコンを取り込みました。"]
        if !unknown.isEmpty {
            let names: String = unknown.prefix(8).joined(separator: "、")
            let more: String = unknown.count > 8 ? " など" : ""
            parts.append("名前が一覧に無いもの（\(unknown.count) 個）：" + names + more)
        }
        if !failed.isEmpty {
            parts.append("読めなかった画像：" + failed.prefix(8).joined(separator: "、"))
        }
        return parts.joined(separator: "\n")
    }
}

/// 取り込んだアイコン（アイコンパック）。設定 > アイコン から ChatGPT などで作った画像を入れると、アプリ中のボタンの絵が替わる。
/// 置き場所の一覧は IconCatalog。取り込んでいない所は SF Symbols を出す。アプリの Assets・Resources に同じ名前の画像があればそれも使う。
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()

    typealias Icon = StoredIcon
    typealias ImportReport = IconImportReport

    /// 取り込んだアイコンが変わるたびに増える（表示を更新する）
    @Published private(set) var revision: Int = 0
    /// id → 色付きか
    @Published private(set) var flags: [String: Bool] = [:]
    private var cache: [String: Icon] = [:]
    private var missing: Set<String> = []
    private var menuCache: [String: UIImage] = [:]
    private var layoutSymbols: [String: String] = [:]

    nonisolated static var folder: URL { return AppPaths.supportFolder("IconPack") }
    nonisolated private static var manifestURL: URL { return folder.appendingPathComponent("manifest.json") }

    init() {
        if let data = try? Data(contentsOf: IconStore.manifestURL),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            flags = decoded
        }
    }

    var importedCount: Int { return flags.count }

    func isImported(_ id: String) -> Bool { return flags[id] != nil }

    /// id の絵（無ければ nil で、呼んだ側が SF Symbols を出す）。
    func icon(_ id: String) -> Icon? {
        if let hit = cache[id] { return hit }
        if missing.contains(id) { return nil }
        let loaded: Icon? = load(id)
        if let found = loaded { cache[id] = found } else { missing.insert(id) }
        return loaded
    }

    private func load(_ id: String) -> Icon? {
        if let isColor = flags[id] {
            let url: URL = IconStore.folder.appendingPathComponent(id + ".png")
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data, scale: 3) {
                return Icon(image: image.withRenderingMode(isColor ? .alwaysOriginal : .alwaysTemplate), isColor: isColor)
            }
        }
        // アプリに入れた画像（Swift Playgrounds の Assets など）。取り込むときと同じようにそろえてから使う
        let bundled: UIImage? = UIImage(named: id) ?? UIImage(named: id + ".png")
        if let image = bundled, let cg = image.cgImage, let result = IconImporter.prepare(cg, id: id),
           let made = IconImporter.image(from: result.bitmap) {
            return Icon(image: made.withRenderingMode(result.isColor ? .alwaysOriginal : .alwaysTemplate), isColor: result.isColor)
        }
        return nil
    }

    /// 大きさを決めるための SF Symbols（古い OS に無い記号なら四角で代わりにする）。
    func layoutSymbol(for id: String) -> String {
        if let known = layoutSymbols[id] { return known }
        let symbol: String = IconCatalog.fallback(for: id)
        let usable: String = UIImage(systemName: symbol) != nil ? symbol : "square"
        layoutSymbols[id] = usable
        return usable
    }

    /// メニュー（長押しのメニューなど）用の小さな絵。メニューは文字の大きさに合わせて伸び縮みしないので、決まった大きさで作る。
    func menuImage(_ id: String) -> UIImage? {
        if let hit = menuCache[id] { return hit }
        guard let found = icon(id) else { return nil }
        let size = CGSize(width: 22, height: 22)
        let renderer = UIGraphicsImageRenderer(size: size)
        let drawn: UIImage = renderer.image { _ in
            found.image.draw(in: CGRect(origin: .zero, size: size))
        }
        let made: UIImage = drawn.withRenderingMode(found.isColor ? .alwaysOriginal : .alwaysTemplate)
        menuCache[id] = made
        return made
    }

    /// UIKit で描く所（タイムラインの見出し）用。単色なら color で塗る。
    func tinted(_ id: String, color: UIColor) -> UIImage? {
        guard let found = icon(id) else { return nil }
        if found.isColor { return found.image }
        return found.image.withTintColor(color, renderingMode: .alwaysOriginal)
    }

    // MARK: 取り込み

    /// ファイル（PNG・JPEG・HEIC・WebP）やフォルダーを取り込む。ファイル名から置き場所を決める。
    func importFiles(_ urls: [URL]) async -> ImportReport {
        var scoped: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() {
            scoped.append(url)
        }
        let folder: URL = IconStore.folder
        let result: (report: ImportReport, flags: [String: Bool]) = await Task.detached(priority: .userInitiated) {
            return IconImporter.importFiles(urls, into: folder)
        }.value
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        apply(result.flags)
        return result.report
    }

    /// 並べて作った 1 枚の画像（シート）を切り分けて取り込む。index はシートの番号（0 から）。
    func importSheet(_ data: Data, index: Int, layout: IconSheetLayout) async -> ImportReport {
        let folder: URL = IconStore.folder
        let result: (report: ImportReport, flags: [String: Bool]) = await Task.detached(priority: .userInitiated) {
            return IconImporter.importSheet(data, index: index, layout: layout, into: folder)
        }.value
        apply(result.flags)
        return result.report
    }

    /// 1 つの置き場所に 1 枚の画像を入れる。
    func importSingle(_ data: Data, id: String) async -> ImportReport {
        let folder: URL = IconStore.folder
        let result: (report: ImportReport, flags: [String: Bool]) = await Task.detached(priority: .userInitiated) {
            return IconImporter.importSingle(data, id: id, into: folder)
        }.value
        apply(result.flags)
        return result.report
    }

    /// 1 つを SF Symbols に戻す。
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: IconStore.folder.appendingPathComponent(id + ".png"))
        var next: [String: Bool] = flags
        next[id] = nil
        flags = next
        saveManifest()
        refresh()
    }

    /// 全部を SF Symbols に戻す。
    func removeAll() {
        try? FileManager.default.removeItem(at: IconStore.folder)
        flags = [:]
        refresh()
    }

    private func apply(_ added: [String: Bool]) {
        if added.isEmpty { return }
        var next: [String: Bool] = flags
        for (id, isColor) in added { next[id] = isColor }
        flags = next
        saveManifest()
        refresh()
    }

    private func refresh() {
        cache = [:]
        missing = []
        menuCache = [:]
        revision += 1
    }

    private func saveManifest() {
        AppPaths.ensure(IconStore.folder)
        if let data = try? JSONEncoder().encode(flags) {
            try? data.write(to: IconStore.manifestURL, options: .atomic)
        }
    }
}

/// 画像の読み込み・そろえ・保存（裏で動かす。UIKit の画面には触らない）。
enum IconImporter {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "tif", "tiff", "gif", "bmp"]

    static func importFiles(_ urls: [URL], into folder: URL) -> (report: IconImportReport, flags: [String: Bool]) {
        var report = IconImportReport()
        var flags: [String: Bool] = [:]
        for file in expand(urls) {
            let name: String = file.lastPathComponent
            guard let id = IconCatalog.id(forFileName: name) else {
                report.unknown.append(name)
                continue
            }
            guard let data = try? Data(contentsOf: file), let isColor = save(data, id: id, into: folder) else {
                report.failed.append(name)
                continue
            }
            flags[id] = isColor
            report.imported.append(id)
        }
        return (report, flags)
    }

    static func importSheet(_ data: Data, index: Int, layout: IconSheetLayout,
                            into folder: URL) -> (report: IconImportReport, flags: [String: Bool]) {
        var report = IconImportReport()
        var flags: [String: Bool] = [:]
        let sheets: [[IconSlot]] = IconCatalog.sheets(layout)
        guard index >= 0 && index < sheets.count, let cg = decode(data, maxSide: 2048), let sheet = bitmap(from: cg, maxSide: 2048) else {
            report.failed.append("シート \(index + 1)")
            return (report, flags)
        }
        let cells: [IconBitmap] = IconImageProcessor.slice(sheet, rows: layout.rows, columns: layout.columns)
        for (position, slot) in sheets[index].enumerated() where position < cells.count {
            guard let result = IconImageProcessor.process(cells[position]), let png = pngData(result.bitmap) else {
                report.failed.append(slot.title)
                continue
            }
            if write(png, id: slot.id, into: folder) {
                flags[slot.id] = result.isColor
                report.imported.append(slot.id)
            } else {
                report.failed.append(slot.title)
            }
        }
        return (report, flags)
    }

    static func importSingle(_ data: Data, id: String, into folder: URL) -> (report: IconImportReport, flags: [String: Bool]) {
        var report = IconImportReport()
        var flags: [String: Bool] = [:]
        if let isColor = save(data, id: id, into: folder) {
            flags[id] = isColor
            report.imported.append(id)
        } else {
            report.failed.append(id)
        }
        return (report, flags)
    }

    /// フォルダーは中の画像ファイルに広げる（下の階層も）。
    static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            let values: URLResourceValues? = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for case let child as URL in walker where imageExtensions.contains(child.pathExtension.lowercased()) {
                    files.append(child)
                }
            } else if imageExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        return files
    }

    /// そろえて保存する。戻り値は色付きか（失敗なら nil）。
    private static func save(_ data: Data, id: String, into folder: URL) -> Bool? {
        guard let cg = decode(data, maxSide: 2048), let result = prepare(cg, id: id), let png = pngData(result.bitmap) else { return nil }
        return write(png, id: id, into: folder) ? result.isColor : nil
    }

    /// 置き場所の形に合わせてそろえる。アイコンは正方形に、ロゴは横長のまま、背景とアプリのアイコンはそのまま（大きさだけ抑える）。
    static func prepare(_ image: CGImage, id: String) -> IconImageProcessor.Result? {
        let slot: IconSlot? = IconCatalog.slot(id)
        switch slot?.shape ?? .square {
        case .backdrop, .appIcon:
            guard let input = bitmap(from: image, maxSide: 2048) else { return nil }
            return IconImageProcessor.Result(bitmap: input, isColor: true)
        case .wide:
            guard let input = bitmap(from: image, maxSide: 2048) else { return nil }
            return IconImageProcessor.processWide(input)
        case .square:
            // イラスト（ロゴ・背景・イラストの分類）は大きめに残す
            let big: Bool = slot?.group == .brand
            guard let input = bitmap(from: image, maxSide: big ? 1024 : 512) else { return nil }
            return IconImageProcessor.process(input, size: big ? 512 : IconImageProcessor.outputSize)
        }
    }

    private static func write(_ png: Data, id: String, into folder: URL) -> Bool {
        AppPaths.ensure(folder)
        do {
            try png.write(to: folder.appendingPathComponent(id + ".png"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 画像を読む（大きい画像は縮めて読む）。
    static func decode(_ data: Data, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [:]
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        options[kCGImageSourceCreateThumbnailWithTransform] = true
        options[kCGImageSourceThumbnailMaxPixelSize] = maxSide
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// CGImage → RGBA（前乗算なし）。長い辺が maxSide を超えれば縮める。
    static func bitmap(from image: CGImage, maxSide: Int = 512) -> IconBitmap? {
        let longest: Int = max(image.width, image.height)
        let scale: Double = longest > maxSide ? Double(maxSide) / Double(longest) : 1
        let width: Int = max(1, Int((Double(image.width) * scale).rounded()))
        let height: Int = max(1, Int((Double(image.height) * scale).rounded()))
        var pixels: [UInt8] = Array(repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn: Bool = pixels.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !drawn { return nil }
        // 前乗算を戻す
        var i: Int = 0
        while i < pixels.count {
            let alpha: Int = Int(pixels[i + 3])
            if alpha > 0 && alpha < 255 {
                for c in 0..<3 {
                    pixels[i + c] = UInt8(min(255, Int(pixels[i + c]) * 255 / alpha))
                }
            }
            i += 4
        }
        return IconBitmap(width: width, height: height, pixels: pixels)
    }

    /// RGBA（前乗算なし）→ CGImage。
    static func cgImage(from bitmap: IconBitmap) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func image(from bitmap: IconBitmap) -> UIImage? {
        guard let cg = cgImage(from: bitmap) else { return nil }
        return UIImage(cgImage: cg, scale: 3, orientation: .up)
    }

    static func pngData(_ bitmap: IconBitmap) -> Data? {
        return image(from: bitmap)?.pngData()
    }
}

/// アイコン。取り込んだ絵があればそれを、無ければ SF Symbols を出す。大きさは SF Symbols と同じく文字の大きさ（.font）に合わせる。
struct DVImage: View {
    let id: String
    @ObservedObject private var store: IconStore = IconStore.shared

    init(_ id: String) {
        self.id = id
    }

    var body: some View {
        let symbol: String = store.layoutSymbol(for: id)
        if let custom = store.icon(id) {
            // 見えない SF Symbols で場所と大きさを決め、その上に取り込んだ絵を重ねる
            Image(systemName: symbol)
                .hidden()
                .overlay {
                    Image(uiImage: custom.image)
                        .renderingMode(custom.isColor ? .original : .template)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(1.19)
                }
        } else {
            Image(systemName: symbol)
        }
    }
}

/// 文字とアイコン（Label の代わり）。
struct DVLabel: View {
    let title: String
    let icon: String

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            DVImage(icon)
        }
    }
}

/// メニューの中の文字とアイコン（メニューは決まった大きさの絵しか出せないので別にする）。
struct DVMenuLabel: View {
    let title: String
    let icon: String
    @ObservedObject private var store: IconStore = IconStore.shared

    init(_ title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        if let custom = store.menuImage(icon) {
            Label {
                Text(title)
            } icon: {
                Image(uiImage: custom)
            }
        } else {
            Label(title, systemImage: store.layoutSymbol(for: icon))
        }
    }
}

/// アイコンと名前を縦に並べた選択ボタン（トランジション・ブレンド・図形など）。選んでいるものは光る。
struct IconChoiceButton: View {
    let title: String
    let icon: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                DVImage(icon)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 24)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 4)
            .foregroundStyle(selected ? Color.black : Theme.text)
            .background(selected ? Theme.accent : Theme.raised, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? Theme.accent : Theme.line, lineWidth: 1))
            .shadow(color: Theme.accent.opacity(selected ? 0.45 : 0), radius: 8)
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// ホームの上のロゴ（取り込んだときだけ出す）。
struct BrandLogo: View {
    @ObservedObject private var store: IconStore = IconStore.shared

    var body: some View {
        if let logo = store.icon("brand.logo") {
            Image(uiImage: logo.image)
                .renderingMode(logo.isColor ? .original : .template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxHeight: 56)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Distro VE")
        }
    }
}

/// ホームの背景（取り込んだ画像があればそれを薄く敷く）。
struct BrandBackdrop: View {
    @ObservedObject private var store: IconStore = IconStore.shared

    var body: some View {
        ZStack {
            Theme.background
            if let backdrop = store.icon("brand.background") {
                Image(uiImage: backdrop.image)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFill()
                    .opacity(0.55)
                LinearGradient(colors: [Theme.background.opacity(0.2), Theme.background.opacity(0.85)], startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

/// 押している間だけ少し縮む（触った手ごたえ）。
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
