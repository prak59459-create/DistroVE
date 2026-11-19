import SwiftUI

/// アプリ全体の設定（Q63, Q64, Q69, Q70）。UserDefaults に保存する。
@MainActor
final class AppSettings: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case dark
        case light
        case system

        var id: String { return rawValue }

        var label: String {
            switch self {
            case .dark: return "ダーク（プロ向け）"
            case .light: return "ライト"
            case .system: return "端末に合わせる"
            }
        }
    }

    enum TextSize: String, CaseIterable, Identifiable {
        case system
        case large
        case extraLarge

        var id: String { return rawValue }

        var label: String {
            switch self {
            case .system: return "端末の設定に合わせる"
            case .large: return "大きめ"
            case .extraLarge: return "とても大きい"
            }
        }

        var range: ClosedRange<DynamicTypeSize> {
            switch self {
            case .system: return DynamicTypeSize.xSmall...DynamicTypeSize.accessibility3
            case .large: return DynamicTypeSize.xLarge...DynamicTypeSize.xLarge
            case .extraLarge: return DynamicTypeSize.xxxLarge...DynamicTypeSize.xxxLarge
            }
        }
    }

    /// パネルの配置（Q70）
    enum InspectorPosition: String, CaseIterable, Identifiable {
        case right
        case left
        case bottom

        var id: String { return rawValue }

        var label: String {
            switch self {
            case .right: return "右"
            case .left: return "左"
            case .bottom: return "下"
            }
        }
    }

    @Published var theme: Theme { didSet { store(theme.rawValue, "theme") } }
    @Published var textSize: TextSize { didSet { store(textSize.rawValue, "textSize") } }
    @Published var colorBlindPalette: Bool { didSet { store(colorBlindPalette, "colorBlindPalette") } }
    @Published var inspectorPosition: InspectorPosition { didSet { store(inspectorPosition.rawValue, "inspectorPosition") } }
    @Published var toolbarAtTop: Bool { didSet { store(toolbarAtTop, "toolbarAtTop") } }
    @Published var copyMediaOnImport: Bool { didSet { store(copyMediaOnImport, "copyMediaOnImport") } }
    @Published var autoProxy: Bool { didSet { store(autoProxy, "autoProxy") } }
    @Published var allowServerSpeech: Bool { didSet { store(allowServerSpeech, "allowServerSpeech") } }
    @Published var hasSeenTutorial: Bool { didSet { store(hasSeenTutorial, "hasSeenTutorial") } }
    @Published var snapping: Bool { didSet { store(snapping, "snapping") } }
    /// キーボードショートカットの割り当て（Q70）。動作 → キー（1 文字）
    @Published var shortcuts: [String: String] { didSet { saveShortcuts() } }

    init() {
        let d = UserDefaults.standard
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .dark
        textSize = TextSize(rawValue: d.string(forKey: "textSize") ?? "") ?? .system
        colorBlindPalette = d.bool(forKey: "colorBlindPalette")
        inspectorPosition = InspectorPosition(rawValue: d.string(forKey: "inspectorPosition") ?? "") ?? .right
        toolbarAtTop = d.bool(forKey: "toolbarAtTop")
        copyMediaOnImport = d.object(forKey: "copyMediaOnImport") as? Bool ?? true
        autoProxy = d.object(forKey: "autoProxy") as? Bool ?? true
        allowServerSpeech = d.bool(forKey: "allowServerSpeech")
        hasSeenTutorial = d.bool(forKey: "hasSeenTutorial")
        snapping = d.object(forKey: "snapping") as? Bool ?? true
        if let data = d.data(forKey: "shortcuts"), let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            shortcuts = decoded
        } else {
            shortcuts = ShortcutAction.defaults
        }
    }

    var colorScheme: ColorScheme? {
        switch theme {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    func key(for action: ShortcutAction) -> KeyEquivalent {
        let text: String = shortcuts[action.rawValue] ?? ShortcutAction.defaults[action.rawValue] ?? ""
        if text == "space" { return .space }
        if text == "delete" { return .delete }
        if text == "left" { return .leftArrow }
        if text == "right" { return .rightArrow }
        return KeyEquivalent(text.first ?? " ")
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            UserDefaults.standard.set(data, forKey: "shortcuts")
        }
    }
}

/// キーボードショートカットの動作。
enum ShortcutAction: String, CaseIterable, Identifiable {
    case playPause
    case split
    case delete
    case rippleDelete
    case undo
    case redo
    case save
    case export
    case previousFrame
    case nextFrame
    case marker
    case zoomIn
    case zoomOut
    case inPoint
    case outPoint

    var id: String { return rawValue }

    static let defaults: [String: String] = [
        "playPause": "space", "split": "b", "delete": "delete", "rippleDelete": "delete",
        "undo": "z", "redo": "z", "save": "s", "export": "e", "previousFrame": "left", "nextFrame": "right",
        "marker": "m", "zoomIn": "=", "zoomOut": "-", "inPoint": "i", "outPoint": "o"
    ]

    var label: String {
        switch self {
        case .playPause: return "再生・停止"
        case .split: return "分割（⌘）"
        case .delete: return "削除"
        case .rippleDelete: return "リップル削除（⇧）"
        case .undo: return "元に戻す（⌘）"
        case .redo: return "やり直し（⌘⇧）"
        case .save: return "保存（⌘）"
        case .export: return "書き出し（⌘）"
        case .previousFrame: return "1 コマ戻る"
        case .nextFrame: return "1 コマ進む"
        case .marker: return "マーカー"
        case .zoomIn: return "拡大（⌘）"
        case .zoomOut: return "縮小（⌘）"
        case .inPoint: return "範囲の開始"
        case .outPoint: return "範囲の終了"
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .split, .undo, .save, .export, .zoomIn, .zoomOut: return .command
        case .redo: return [.command, .shift]
        case .rippleDelete: return .shift
        default: return []
        }
    }

    /// 変更できるもの（⌘Z などの決まった操作は変えない）
    var isCustomizable: Bool {
        switch self {
        case .undo, .redo, .save: return false
        default: return true
        }
    }
}
