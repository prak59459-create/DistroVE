import XCTest
@testable import DistroKit

/// アイコンの一覧（開発者が ChatGPT で作り、アプリの Assets に入れる絵の置き場所）。
final class IconCatalogTests: XCTestCase {
    /// scripts/icon_pack.py と同じ比べ方（小文字にして英数字だけ残す）。ファイル名の書き方が違っても 1 つに決まるように。
    private func key(_ text: String) -> String {
        var result: String = ""
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    func testIDsAreUniqueEvenIgnoringCaseAndSymbols() {
        var ids = Set<String>()
        var keys = Set<String>()
        var assets = Set<String>()
        for slot in IconCatalog.all {
            XCTAssertTrue(ids.insert(slot.id).inserted, "重複: \(slot.id)")
            XCTAssertTrue(keys.insert(key(slot.id)).inserted, "記号を除くと重複: \(slot.id)")
            // Assets の名前は「.」を「_」にしたもの（重ならず、「.」を含まない）
            let asset: String = IconCatalog.assetName(for: slot.id)
            XCTAssertTrue(assets.insert(asset).inserted, asset)
            XCTAssertFalse(asset.contains("."), asset)
            XCTAssertFalse(slot.fallback.isEmpty, slot.id)
            XCTAssertFalse(slot.title.isEmpty, slot.id)
            XCTAssertGreaterThan(slot.prompt.count, 3, slot.id)
            // ファイル名に使える文字だけ
            for scalar in slot.id.unicodeScalars {
                XCTAssertTrue(CharacterSet.alphanumerics.contains(scalar) || scalar == ".", slot.id)
            }
        }
        XCTAssertGreaterThan(IconCatalog.all.count, 200)
    }

    func testEveryChoiceHasItsOwnIcon() {
        for tool in RootTool.allCases { XCTAssertNotNil(IconCatalog.slot(tool.iconID), tool.rawValue) }
        for kind in EffectKind.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in TransitionKind.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in AnimationKind.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in TextAnimation.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in ShapeKind.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in MaskShape.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in FitMode.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in AspectPreset.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in LayerBlend.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in Object3DKind.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in Lighting3D.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in Motion3D.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in EQPreset.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in VoicePreset.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in FrameInterpolation.allCases { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for kind in [MediaKind.video, .audio, .image, .gif, .model3D] { XCTAssertNotNil(IconCatalog.slot(kind.iconID), kind.rawValue) }
        for preset in SpeedMap.presets { XCTAssertNotNil(IconCatalog.slot("speed." + preset.id), preset.id) }
        for preset in ExportPreset.all { XCTAssertNotNil(IconCatalog.slot("export." + preset.id), preset.id) }
    }

    func testSheetsCoverEveryIconOnce() {
        for layout in IconSheetLayout.allCases {
            var seen = Set<String>()
            for sheet in IconCatalog.sheets(layout) {
                XCTAssertLessThanOrEqual(sheet.count, layout.capacity, layout.rawValue)
                XCTAssertFalse(sheet.isEmpty, layout.rawValue)
                for slot in sheet {
                    XCTAssertTrue(seen.insert(slot.id).inserted, slot.id)
                    XCTAssertEqual(slot.shape, .square, slot.id)
                }
            }
            XCTAssertEqual(seen.count, IconCatalog.sheetSlots.count, layout.rawValue)
        }
        // まとめると、ちょうど 6 枚。増えて 7 枚目ができたら sixSheetGroups を見直す
        XCTAssertEqual(IconCatalog.sheets(.six).count, 6)
        for (index, groups) in IconCatalog.sixSheetGroups.enumerated() {
            for slot in IconCatalog.sheets(.six)[index] {
                XCTAssertTrue(groups.contains(slot.group), "画像 \(index + 1) に \(slot.id)")
            }
        }
        // 別に作るのは、アプリのアイコン・ロゴ・背景の 3 枚だけ
        let separate: [String] = IconCatalog.all.filter { $0.shape != .square }.map { $0.id }.sorted()
        XCTAssertEqual(separate, ["app.icon", "brand.background", "brand.logo"])
        XCTAssertEqual(IconCatalog.sheetTitle(0, layout: .six), "ホーム・プロジェクト・下の道具バー・書き出し")
        XCTAssertEqual(IconCatalog.sheetTitle(99, layout: .six), "")
    }

    func testFallbacks() {
        XCTAssertEqual(IconCatalog.assetName(for: "edit.split"), "edit_split")
        XCTAssertEqual(IconCatalog.fallback(for: "edit.split"), "scissors")
        XCTAssertEqual(IconCatalog.fallback(for: "trash"), "trash")
    }
}

/// ChatGPT 用のプロンプトと、その説明書（docs/アイコン制作プロンプト.md）、scripts/icon_pack.py が使う並び順（scripts/icon_layout.json）。
final class IconPromptTests: XCTestCase {
    private var documentURL: URL {
        let tests: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return tests.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/アイコン制作プロンプト.md")
    }

    func testPromptsNameEveryIconInOrder() {
        for style in IconStyle.allCases {
            let guide: String = IconPrompt.styleGuide(style)
            XCTAssertTrue(guide.contains("transparent"), style.rawValue)
            XCTAssertTrue(guide.contains("columns"), style.rawValue)
        }
        for layout in IconSheetLayout.allCases {
            let sheets: [[IconSlot]] = IconCatalog.sheets(layout)
            for (index, sheet) in sheets.enumerated() {
                let text: String = IconPrompt.sheet(index, style: .neon, layout: layout)
                XCTAssertTrue(text.contains("\(layout.width)x\(layout.height)"), layout.rawValue)
                XCTAssertTrue(text.contains("\(layout.columns) columns × \(layout.rows) rows"), layout.rawValue)
                var cursor: String.Index = text.startIndex
                for slot in sheet {
                    // 順番どおりに並んでいる
                    guard let found = text.range(of: "[\(slot.id)]", range: cursor..<text.endIndex) else {
                        XCTFail("\(layout.rawValue) シート \(index + 1) に \(slot.id) が無い")
                        continue
                    }
                    cursor = found.upperBound
                }
                let empty: Int = layout.capacity - sheet.count
                XCTAssertEqual(text.contains("Leave the last \(empty) cell"), empty > 0, "\(layout.rawValue) \(index + 1)")
            }
            XCTAssertEqual(IconPrompt.sheet(sheets.count, style: .proLine, layout: layout), "")
        }
        XCTAssertTrue(IconPrompt.appIcon(.glass3D).contains("1024x1024"))
    }

    private var layoutURL: URL {
        let tests: URL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return tests.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/icon_layout.json")
    }

    /// scripts/icon_layout.json がコードと同じか（UPDATE_ICON_DOC=1 で書き直す）。
    func testLayoutFileIsUpToDate() throws {
        let made: String = IconLayoutFile.json()
        if ProcessInfo.processInfo.environment["UPDATE_ICON_DOC"] == "1" {
            try made.write(to: layoutURL, atomically: true, encoding: .utf8)
        }
        let saved: String = try String(contentsOf: layoutURL, encoding: .utf8)
        XCTAssertEqual(saved, made, "scripts/icon_layout.json が古いです。UPDATE_ICON_DOC=1 swift test --filter IconPromptTests で作り直してください。")
        // JSON として読めて、どのマスも一覧にある絵を指している
        let parsed: Any = try JSONSerialization.jsonObject(with: Data(made.utf8))
        let root: [String: Any] = try XCTUnwrap(parsed as? [String: Any])
        let icons: [[String: Any]] = try XCTUnwrap(root["icons"] as? [[String: Any]])
        XCTAssertEqual(icons.count, IconCatalog.all.count)
        let layouts: [String: Any] = try XCTUnwrap(root["layouts"] as? [String: Any])
        for layout in IconSheetLayout.allCases {
            let entry: [String: Any] = try XCTUnwrap(layouts[layout.rawValue] as? [String: Any])
            let sheets: [[String]] = try XCTUnwrap(entry["sheets"] as? [[String]])
            XCTAssertEqual(sheets, IconCatalog.sheets(layout).map { $0.map { $0.id } })
        }
        XCTAssertEqual(IconLayoutFile.quote("a\"b\\c\u{1}"), "\"a\\\"b\\\\c\\u0001\"")
    }

    /// 説明書がコードと同じか（UPDATE_ICON_DOC=1 で書き直す）。
    func testDocumentIsUpToDate() throws {
        let made: String = IconPrompt.document()
        if ProcessInfo.processInfo.environment["UPDATE_ICON_DOC"] == "1" {
            try made.write(to: documentURL, atomically: true, encoding: .utf8)
        }
        let saved: String = try String(contentsOf: documentURL, encoding: .utf8)
        XCTAssertEqual(saved, made, "docs/アイコン制作プロンプト.md が古いです。UPDATE_ICON_DOC=1 swift test --filter IconPromptTests で作り直してください。")
        for slot in IconCatalog.all {
            XCTAssertTrue(made.contains("`\(slot.fileName)`"), slot.id)
        }
    }
}
