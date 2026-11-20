import SwiftUI
import UIKit

/// アプリに入れた絵 1 つ。
struct StoredIcon {
    let image: UIImage
    /// 色付き（そのまま出す）か、単色（文字の色で塗る）か
    let isColor: Bool
}

/// アプリに入れたアイコン。開発者が ChatGPT で作り、scripts/icon_pack.py で DistroVE.swiftpm/Assets.xcassets に入れたもの。
/// 置き場所の一覧は IconCatalog。絵が入っていない所は SF Symbols を出す。
/// 背景の透明化・大きさのそろえは済んでいる。単色の絵は Assets で「テンプレート」になっているので、アプリの文字の色で塗る。
@MainActor
final class IconStore {
    static let shared = IconStore()

    private var cache: [String: StoredIcon] = [:]
    private var missing: Set<String> = []
    private var menuCache: [String: UIImage] = [:]
    private var layoutSymbols: [String: String] = [:]

    /// id の絵（無ければ nil で、呼んだ側が SF Symbols を出す）。
    func icon(_ id: String) -> StoredIcon? {
        if let hit = cache[id] { return hit }
        if missing.contains(id) { return nil }
        guard let image = UIImage(named: IconCatalog.assetName(for: id)) else {
            missing.insert(id)
            return nil
        }
        let found = StoredIcon(image: image, isColor: image.renderingMode != .alwaysTemplate)
        cache[id] = found
        return found
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
}

/// アイコン。アプリに入れた絵があればそれを、無ければ SF Symbols を出す。大きさは SF Symbols と同じく文字の大きさ（.font）に合わせる。
struct DVImage: View {
    let id: String
    private let store: IconStore = IconStore.shared

    init(_ id: String) {
        self.id = id
    }

    var body: some View {
        let symbol: String = store.layoutSymbol(for: id)
        if let custom = store.icon(id) {
            // 見えない SF Symbols で場所と大きさを決め、その上にアプリに入れた絵を重ねる
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
    private let store: IconStore = IconStore.shared

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

/// ホームの上のロゴ（アプリに入れたときだけ出す）。
struct BrandLogo: View {
    private let store: IconStore = IconStore.shared

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

/// ホームの背景（アプリに入れた画像があればそれを薄く敷く）。
struct BrandBackdrop: View {
    private let store: IconStore = IconStore.shared

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
