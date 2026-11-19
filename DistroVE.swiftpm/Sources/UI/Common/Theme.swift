import SwiftUI
import UIKit

/// プロ向けのダーク調を基本にした色（Q63, Q64）。ライトでも読めるよう、すべて明暗で切り替わる色にする。
enum Theme {
    static func dynamic(_ dark: UInt32, _ light: UInt32) -> UIColor {
        return UIColor { traits in
            return traits.userInterfaceStyle == .light ? UIColor(hex: light) : UIColor(hex: dark)
        }
    }

    static let backgroundUI: UIColor = dynamic(0x0E0F12, 0xF2F3F5)
    static let panelUI: UIColor = dynamic(0x16181D, 0xFFFFFF)
    static let raisedUI: UIColor = dynamic(0x1F2228, 0xE9EBEF)
    static let lineUI: UIColor = dynamic(0x2B2F37, 0xD3D6DC)
    static let textUI: UIColor = dynamic(0xECEEF2, 0x15171B)
    static let subtextUI: UIColor = dynamic(0x9AA0AA, 0x5C6370)
    static let accentUI: UIColor = UIColor(hex: 0xFF7A1A)
    static let playheadUI: UIColor = dynamic(0xFFFFFF, 0x111111)

    static let background = Color(uiColor: backgroundUI)
    static let panel = Color(uiColor: panelUI)
    static let raised = Color(uiColor: raisedUI)
    static let line = Color(uiColor: lineUI)
    static let text = Color(uiColor: textUI)
    static let subtext = Color(uiColor: subtextUI)
    static let accent = Color(uiColor: accentUI)
}

/// クリップの色。色覚に配慮した配色（Okabe–Ito）にも切り替えられる（Q69）。
struct TrackPalette {
    let colorBlind: Bool

    func color(for kind: ClipKind) -> UIColor {
        if colorBlind {
            switch kind {
            case .video: return UIColor(hex: 0x0072B2)
            case .image, .gif: return UIColor(hex: 0x56B4E9)
            case .text: return UIColor(hex: 0xCC79A7)
            case .audio: return UIColor(hex: 0x009E73)
            case .sticker: return UIColor(hex: 0xE69F00)
            case .shape: return UIColor(hex: 0xF0E442)
            case .solid: return UIColor(hex: 0x7F7F7F)
            case .adjustment: return UIColor(hex: 0xBBBBBB)
            case .object3D: return UIColor(hex: 0xD55E00)
            }
        }
        switch kind {
        case .video: return UIColor(hex: 0x3D7BFF)
        case .image, .gif: return UIColor(hex: 0x7C5CFF)
        case .text: return UIColor(hex: 0xFF4F87)
        case .audio: return UIColor(hex: 0x22B566)
        case .sticker: return UIColor(hex: 0xF59E0B)
        case .shape: return UIColor(hex: 0x06A6C4)
        case .solid: return UIColor(hex: 0x6B7280)
        case .adjustment: return UIColor(hex: 0x9CA3AF)
        case .object3D: return UIColor(hex: 0xF97316)
        }
    }

    var subtitle: UIColor {
        return colorBlind ? UIColor(hex: 0xD55E00) : UIColor(hex: 0xEAB308)
    }

    var beat: UIColor {
        return colorBlind ? UIColor(hex: 0xF0E442) : UIColor(hex: 0xFFD23F)
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        let r: CGFloat = CGFloat((hex >> 16) & 0xFF) / 255
        let g: CGFloat = CGFloat((hex >> 8) & 0xFF) / 255
        let b: CGFloat = CGFloat(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

extension RGBA {
    var color: Color {
        return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    init(_ color: Color) {
        let ui = UIColor(color)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(Double(r), Double(g), Double(b), Double(a))
    }
}

/// 小さな共通部品。
struct PanelTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.subtext)
            .textCase(nil)
    }
}

/// ツールバーのボタン（アイコンと文字）。
struct ToolButton: View {
    let title: String
    let symbol: String
    var isActive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 22)
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
            }
            .frame(minWidth: 54)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .foregroundStyle(isActive ? Theme.accent : Theme.text)
            .background(isActive ? Theme.accent.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .hoverEffect(.highlight)
        .accessibilityLabel(title)
    }
}

/// キーフレームを打てるスライダー 1 行。
struct ParamRow: View {
    let label: String
    let range: ClosedRange<Double>
    let value: Double
    var format: String = "%.2f"
    var keyState: KeyState = .none
    let onChange: (Double) -> Void
    var onToggleKey: (() -> Void)?
    var onReset: (() -> Void)?

    enum KeyState {
        case none
        case animated
        case onKey
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.text)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Slider(value: binding, in: range)
                .tint(Theme.accent)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.subtext)
                .frame(width: 50, alignment: .trailing)
            if let toggle = onToggleKey {
                Button(action: toggle) {
                    Image(systemName: keyIcon)
                        .foregroundStyle(keyState == .none ? Theme.subtext : Theme.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("キーフレーム")
            }
            if let reset = onReset {
                Button(action: reset) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.caption)
                        .foregroundStyle(Theme.subtext)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("元に戻す")
            }
        }
        .padding(.vertical, 2)
    }

    private var keyIcon: String {
        switch keyState {
        case .none: return "diamond"
        case .animated: return "diamond.bottomhalf.filled"
        case .onKey: return "diamond.fill"
        }
    }

    private var binding: Binding<Double> {
        return Binding<Double>(get: { value }, set: { onChange($0) })
    }
}

/// 選択肢のチップを横に並べる。
struct ChipPicker<Item: Hashable>: View {
    let items: [Item]
    let selection: Item?
    let label: (Item) -> String
    let onSelect: (Item) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    chip(item)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ item: Item) -> some View {
        let selected: Bool = item == selection
        return Button {
            onSelect(item)
        } label: {
            Text(label(item))
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.black : Theme.text)
                .background(selected ? Theme.accent : Theme.raised, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
