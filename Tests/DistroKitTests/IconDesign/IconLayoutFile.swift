import Foundation
@testable import DistroKit

/// scripts/icon_layout.json を作る。scripts/icon_pack.py はこの一覧で、シートのどのマスがどの絵か・Assets の中の名前・書き出す大きさを知る。
/// 中身は IconCatalog から作り、テスト（IconPromptTests）が保存されたファイルと同じか確かめる（UPDATE_ICON_DOC=1 で書き直す）。
enum IconLayoutFile {
    /// 書き出す画像の大きさ（画素）。正方形はこの大きさの正方形に、ロゴと背景は長い辺をこの大きさまでにする。
    static func outputSize(_ slot: IconSlot) -> Int {
        switch slot.shape {
        case .square: return slot.group == .brand ? 512 : 256
        case .wide: return 1024
        case .backdrop: return 2048
        case .appIcon: return 1024
        }
    }

    /// 1 行に 1 つずつ書く（差分が読みやすいように、並びもいつも同じにする）。
    static func json() -> String {
        var out: [String] = []
        out.append("{")
        out.append("  \"version\": 1,")
        out.append("  \"fill\": 0.84,")
        out.append("  \"icons\": [")
        var icons: [String] = []
        for slot in IconCatalog.all {
            var fields: [String] = []
            fields.append("\"id\": " + quote(slot.id))
            fields.append("\"asset\": " + quote(IconCatalog.assetName(for: slot.id)))
            fields.append("\"shape\": " + quote(slot.shape.rawValue))
            fields.append("\"size\": \(outputSize(slot))")
            fields.append("\"title\": " + quote(slot.title))
            icons.append("    {" + fields.joined(separator: ", ") + "}")
        }
        out.append(icons.joined(separator: ",\n"))
        out.append("  ],")
        out.append("  \"layouts\": {")
        var layouts: [String] = []
        for layout in IconSheetLayout.allCases {
            var lines: [String] = []
            lines.append("    " + quote(layout.rawValue) + ": {")
            lines.append("      \"prefix\": \(quote(layout.filePrefix)), \"columns\": \(layout.columns), \"rows\": \(layout.rows), \"width\": \(layout.width), \"height\": \(layout.height),")
            lines.append("      \"sheets\": [")
            var sheets: [String] = []
            for sheet in IconCatalog.sheets(layout) {
                sheets.append("        [" + sheet.map { quote($0.id) }.joined(separator: ", ") + "]")
            }
            lines.append(sheets.joined(separator: ",\n"))
            lines.append("      ]")
            lines.append("    }")
            layouts.append(lines.joined(separator: "\n"))
        }
        out.append(layouts.joined(separator: ",\n"))
        out.append("  }")
        out.append("}")
        out.append("")
        return out.joined(separator: "\n")
    }

    /// JSON の文字列（日本語はそのまま書く）。
    static func quote(_ text: String) -> String {
        var result: String = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }
}
