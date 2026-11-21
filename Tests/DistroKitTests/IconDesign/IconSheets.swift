import Foundation
@testable import DistroKit

/// 1 枚の画像に何個並べて作るか（開発者が ChatGPT で作るときの形。アプリには入らない）。
enum IconSheetLayout: String, CaseIterable, Sendable {
    /// 6 枚にまとめる（横長 1536×1024 に 8 列 × 6 行）
    case six
    /// 細かく作る（正方形 1024×1024 に 4 列 × 4 行。1 つずつがきれいに出やすい）
    case detailed

    var columns: Int { return self == .six ? 8 : 4 }
    var rows: Int { return self == .six ? 6 : 4 }
    var capacity: Int { return columns * rows }
    var width: Int { return self == .six ? 1536 : 1024 }
    var height: Int { return 1024 }

    /// Design/Icons/ に置くときのファイル名の始まり（sheet-1.png、detailed-1.png）
    var filePrefix: String { return self == .six ? "sheet" : "detailed" }

    var title: String {
        switch self {
        case .six: return "6 枚にまとめる（1 枚に 48 個）"
        case .detailed: return "細かく作る（1 枚に 16 個）"
        }
    }
}

/// 開発者が ChatGPT で作るときの、シートごとの並び。scripts/icon_layout.json に書き出し、scripts/icon_pack.py が切り分けに使う。
extension IconCatalog {
    /// 1 枚の画像に並べて作る絵（アイコンと、正方形のイラスト）。ロゴ・背景・アプリのアイコンは形が違うので 1 枚ずつ作る。
    static var sheetSlots: [IconSlot] {
        return all.filter { $0.shape == .square }
    }

    /// まとめて作るときの 6 枚の組み合わせ（似た分類を同じ画像に入れて、絵柄をそろえる）。どれも 8 列 × 6 行の 48 個に収まる。
    static let sixSheetGroups: [[IconGroup]] = [
        [.home, .tools, .export],
        [.editing, .playback, .timeline],
        [.media, .text, .ai],
        [.effects, .transitions, .animations],
        [.shapes, .object3D, .brand],
        [.blend, .audio, .speed, .status]
    ]

    private static let sixSheets: [[IconSlot]] = {
        var result: [[IconSlot]] = []
        let capacity: Int = IconSheetLayout.six.capacity
        for groups in sixSheetGroups {
            var sheet: [IconSlot] = []
            for group in groups {
                for slot in slots(in: group) where slot.shape == .square {
                    sheet.append(slot)
                }
            }
            // 増えて入りきらなくなったら、あふれたぶんを次の画像にする（一覧のテストで気づけるようにする）
            while sheet.count > capacity {
                result.append(Array(sheet.prefix(capacity)))
                sheet = Array(sheet.dropFirst(capacity))
            }
            if !sheet.isEmpty { result.append(sheet) }
        }
        // 組み合わせに入れ忘れた分類があれば、最後に足す
        var placed = Set<String>()
        for sheet in result {
            for slot in sheet { placed.insert(slot.id) }
        }
        let rest: [IconSlot] = sheetSlots.filter { !placed.contains($0.id) }
        var index: Int = 0
        while index < rest.count {
            result.append(Array(rest[index..<min(rest.count, index + capacity)]))
            index += capacity
        }
        return result
    }()

    /// 細かく作るとき（4×4 の 16 個ずつ）。同じ分類はなるべく同じシートに入れる。
    private static let detailedSheets: [[IconSlot]] = {
        let capacity: Int = IconSheetLayout.detailed.capacity
        var result: [[IconSlot]] = []
        var current: [IconSlot] = []
        var order: [IconGroup] = []
        for group in IconGroup.allCases where group != .brand { order.append(group) }
        order.append(.brand)
        for group in order {
            let items: [IconSlot] = slots(in: group).filter { $0.shape == .square }
            // 分類の途中で切れないよう、入りきらなければ新しいシートにする（大きい分類はそのまま分ける）
            if !current.isEmpty && current.count + items.count > capacity && items.count <= capacity {
                result.append(current)
                current = []
            }
            for item in items {
                current.append(item)
                if current.count == capacity {
                    result.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }()

    static func sheets(_ layout: IconSheetLayout) -> [[IconSlot]] {
        switch layout {
        case .six: return sixSheets
        case .detailed: return detailedSheets
        }
    }

    /// シートの見出し（入っている分類の名前）。
    static func sheetTitle(_ index: Int, layout: IconSheetLayout) -> String {
        let all: [[IconSlot]] = sheets(layout)
        guard index >= 0 && index < all.count else { return "" }
        var names: [String] = []
        for slot in all[index] {
            // シートに入るのは正方形の絵だけ（ロゴと背景は別に作る）なので、ブランドは「イラスト」と呼ぶ
            let name: String = slot.group == .brand ? "イラスト" : slot.group.title
            if !names.contains(name) { names.append(name) }
        }
        return names.joined(separator: "・")
    }
}
