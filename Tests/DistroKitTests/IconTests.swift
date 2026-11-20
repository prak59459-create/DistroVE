import XCTest
@testable import DistroKit

/// 差し替えられるアイコンの一覧（ChatGPT などで作った画像の受け皿）。
final class IconCatalogTests: XCTestCase {
    func testIDsAreUniqueEvenIgnoringCaseAndSymbols() {
        var ids = Set<String>()
        var keys = Set<String>()
        for slot in IconCatalog.all {
            XCTAssertTrue(ids.insert(slot.id).inserted, "重複: \(slot.id)")
            XCTAssertTrue(keys.insert(IconCatalog.key(slot.id)).inserted, "記号を除くと重複: \(slot.id)")
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

    func testFileNamesFromImageToolsAreRecognised() {
        XCTAssertEqual(IconCatalog.id(forFileName: "edit.split.png"), "edit.split")
        XCTAssertEqual(IconCatalog.id(forFileName: "edit_split.PNG"), "edit.split")
        XCTAssertEqual(IconCatalog.id(forFileName: "Edit-Split@2x.png"), "edit.split")
        XCTAssertEqual(IconCatalog.id(forFileName: "07_edit.rippleDelete.png"), "edit.rippleDelete")
        XCTAssertEqual(IconCatalog.id(forFileName: "effect_zoom_blur.webp"), "effect.zoomBlur")
        XCTAssertEqual(IconCatalog.id(forFileName: "transition.cube3D"), "transition.cube3D")
        // SF Symbols の名前で作ったファイルも、その記号を使う置き場所に入る
        XCTAssertEqual(IconCatalog.id(forFileName: "speedometer.png"), "edit.speed")
        XCTAssertNil(IconCatalog.id(forFileName: "holiday-photo.png"))
        XCTAssertEqual(IconCatalog.fallback(for: "edit.split"), "scissors")
        XCTAssertEqual(IconCatalog.fallback(for: "trash"), "trash")
    }
}

/// 取り込んだアイコンの画像をそろえる処理。
final class IconImageTests: XCTestCase {
    /// 白地に黒い輪（ドーナツ）。中心をずらして小さめに置く。
    private func ringOnWhite() -> IconBitmap {
        var b = IconBitmap(width: 200, height: 160)
        for y in 0..<160 {
            for x in 0..<200 {
                let dx: Double = Double(x) - 70
                let dy: Double = Double(y) - 60
                let r: Double = (dx * dx + dy * dy).squareRoot()
                let ink: Bool = r > 18 && r < 30
                let p: Int = (y * 200 + x) * 4
                let v: UInt8 = ink ? 10 : 250
                b.pixels[p] = v
                b.pixels[p + 1] = v
                b.pixels[p + 2] = v
                b.pixels[p + 3] = 255
            }
        }
        return b
    }

    /// 白地に、オレンジの丸の中に白い丸（色付きのアイコン）。
    private func colorBadgeOnWhite() -> IconBitmap {
        var b = IconBitmap(width: 120, height: 120)
        for y in 0..<120 {
            for x in 0..<120 {
                let dx: Double = Double(x) - 60
                let dy: Double = Double(y) - 60
                let r: Double = (dx * dx + dy * dy).squareRoot()
                let p: Int = (y * 120 + x) * 4
                var color: (UInt8, UInt8, UInt8) = (255, 255, 255)
                if r < 40 { color = (255, 122, 26) }
                if r < 15 { color = (255, 255, 255) }
                b.pixels[p] = color.0
                b.pixels[p + 1] = color.1
                b.pixels[p + 2] = color.2
                b.pixels[p + 3] = 255
            }
        }
        return b
    }

    private func alphaAt(_ b: IconBitmap, _ x: Int, _ y: Int) -> UInt8 {
        return b.pixels[(y * b.width + x) * 4 + 3]
    }

    func testMonochromeGlyphOnWhiteBecomesACenteredTemplate() throws {
        let result: IconImageProcessor.Result = try XCTUnwrap(IconImageProcessor.process(ringOnWhite()))
        XCTAssertFalse(result.isColor)
        let out: IconBitmap = result.bitmap
        XCTAssertEqual(out.width, IconImageProcessor.outputSize)
        XCTAssertEqual(out.height, IconImageProcessor.outputSize)
        // 背景と輪の中の穴は透明、輪は不透明
        XCTAssertEqual(alphaAt(out, 2, 2), 0)
        XCTAssertEqual(alphaAt(out, 128, 128), 0)
        let box = try XCTUnwrap(IconImageProcessor.bounds(out))
        // 真ん中に、大きさの 84% で入る
        XCTAssertEqual(Double(box.x1 - box.x0), 256 * 0.84, accuracy: 3)
        XCTAssertEqual(Double(box.x0 + box.x1) / 2, 128, accuracy: 2)
        XCTAssertEqual(Double(box.y0 + box.y1) / 2, 128, accuracy: 2)
        XCTAssertGreaterThan(alphaAt(out, 128, box.y0 + 8), 200)
        // 単色のアイコンは白くして形だけを残す
        let p: Int = ((box.y0 + 8) * out.width + 128) * 4
        XCTAssertEqual(out.pixels[p], 255)
    }

    func testColorIconKeepsItsColorsAndInnerWhite() throws {
        let result: IconImageProcessor.Result = try XCTUnwrap(IconImageProcessor.process(colorBadgeOnWhite()))
        XCTAssertTrue(result.isColor)
        let out: IconBitmap = result.bitmap
        XCTAssertEqual(alphaAt(out, 3, 3), 0)
        // 縁からつながっていない白（中の丸）は残る
        XCTAssertGreaterThan(alphaAt(out, 128, 128), 240)
        let center: Int = (128 * out.width + 128) * 4
        XCTAssertGreaterThan(out.pixels[center + 2], 240)
        // オレンジの部分の色はそのまま
        let ring: Int = (128 * out.width + 128 + 60) * 4
        XCTAssertGreaterThan(out.pixels[ring], 240)
        XCTAssertLessThan(out.pixels[ring + 2], 60)
    }

    func testTransparentInputKeepsItsAlpha() throws {
        var b = IconBitmap(width: 64, height: 64)
        for y in 40..<56 {
            for x in 4..<20 {
                let p: Int = (y * 64 + x) * 4
                b.pixels[p] = 0
                b.pixels[p + 1] = 0
                b.pixels[p + 2] = 0
                b.pixels[p + 3] = 255
            }
        }
        let result: IconImageProcessor.Result = try XCTUnwrap(IconImageProcessor.process(b))
        XCTAssertFalse(result.isColor)
        let box = try XCTUnwrap(IconImageProcessor.bounds(result.bitmap))
        XCTAssertEqual(Double(box.x0 + box.x1) / 2, 128, accuracy: 2)
        XCTAssertEqual(Double(box.x1 - box.x0), 256 * 0.84, accuracy: 3)
        // 何も描いていない絵は使えない
        XCTAssertNil(IconImageProcessor.process(IconBitmap(width: 32, height: 32)))
    }

    func testSheetIsSlicedAtTheGapsInReadingOrder() throws {
        // 2 行 × 3 列。白地に、マスごとに幅の違う黒い四角を、少しずつずらして置く
        let width: Int = 300
        let height: Int = 200
        var b = IconBitmap(width: width, height: height)
        for i in 0..<(width * height) {
            b.pixels[i * 4] = 255
            b.pixels[i * 4 + 1] = 255
            b.pixels[i * 4 + 2] = 255
            b.pixels[i * 4 + 3] = 255
        }
        let widths: [Int] = [10, 20, 30, 40, 50, 60]
        for cell in 0..<6 {
            let column: Int = cell % 3
            let row: Int = cell / 3
            let left: Int = column * 100 + 20 + (cell % 2) * 8
            let top: Int = row * 100 + 25
            for y in top..<(top + 40) {
                for x in left..<(left + widths[cell]) {
                    let p: Int = (y * width + x) * 4
                    b.pixels[p] = 0
                    b.pixels[p + 1] = 0
                    b.pixels[p + 2] = 0
                }
            }
        }
        let cells: [IconBitmap] = IconImageProcessor.slice(b, rows: 2, columns: 3)
        XCTAssertEqual(cells.count, 6)
        for (i, cell) in cells.enumerated() {
            let box = try XCTUnwrap(IconImageProcessor.bounds(cell), "マス \(i)")
            XCTAssertEqual(box.x1 - box.x0, widths[i], "マス \(i)")
            XCTAssertEqual(box.y1 - box.y0, 40, "マス \(i)")
        }
        XCTAssertEqual(IconImageProcessor.cuts(mass: [0, 5, 5, 0, 0, 5, 5, 0], parts: 2), [0, 4, 8])
    }

    func testSixSheetIsSlicedIntoEightColumnsAndSixRows() throws {
        // 1536×1024 を 1/4 にした大きさ（マスの高さは割り切れない 42.67）。マスごとに幅を変えて、順番を確かめる
        let layout: IconSheetLayout = .six
        let width: Int = layout.width / 4
        let height: Int = layout.height / 4
        var b = IconBitmap(width: width, height: height)
        for i in 0..<(width * height) {
            b.pixels[i * 4] = 255
            b.pixels[i * 4 + 1] = 255
            b.pixels[i * 4 + 2] = 255
            b.pixels[i * 4 + 3] = 255
        }
        let cellWidth: Double = Double(width) / Double(layout.columns)
        let cellHeight: Double = Double(height) / Double(layout.rows)
        for cell in 0..<layout.capacity {
            let column: Int = cell % layout.columns
            let row: Int = cell / layout.columns
            let markWidth: Int = 6 + cell % 20
            let left: Int = Int(Double(column) * cellWidth) + 8 + (cell % 3)
            let top: Int = Int(Double(row) * cellHeight) + 10
            for y in top..<(top + 20) {
                for x in left..<(left + markWidth) {
                    let p: Int = (y * width + x) * 4
                    b.pixels[p] = 0
                    b.pixels[p + 1] = 0
                    b.pixels[p + 2] = 0
                }
            }
        }
        let cells: [IconBitmap] = IconImageProcessor.slice(b, rows: layout.rows, columns: layout.columns)
        XCTAssertEqual(cells.count, 48)
        for (i, cell) in cells.enumerated() {
            let box = try XCTUnwrap(IconImageProcessor.bounds(cell), "マス \(i)")
            XCTAssertEqual(box.x1 - box.x0, 6 + i % 20, "マス \(i)")
            XCTAssertEqual(box.y1 - box.y0, 20, "マス \(i)")
        }
    }
}


/// ChatGPT 用のプロンプトと、その説明書（docs/アイコン制作プロンプト.md）。
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
                let slicing: String = IconPrompt.slicing(index, layout: layout)
                XCTAssertTrue(slicing.contains(sheet[0].fileName))
                XCTAssertTrue(slicing.contains(sheet[sheet.count - 1].fileName))
            }
            XCTAssertEqual(IconPrompt.sheet(sheets.count, style: .proLine, layout: layout), "")
        }
        XCTAssertTrue(IconPrompt.appIcon(.glass3D).contains("1024x1024"))
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

final class IconWideImageTests: XCTestCase {
    func testWideLogoKeepsItsShape() throws {
        // 白地に横長の黒い帯（300×60）。真ん中から外れた所に置く
        var b = IconBitmap(width: 600, height: 300)
        for i in 0..<(600 * 300) {
            b.pixels[i * 4] = 255
            b.pixels[i * 4 + 1] = 255
            b.pixels[i * 4 + 2] = 255
            b.pixels[i * 4 + 3] = 255
        }
        for y in 40..<100 {
            for x in 50..<350 {
                let p: Int = (y * 600 + x) * 4
                b.pixels[p] = 0
                b.pixels[p + 1] = 0
                b.pixels[p + 2] = 0
            }
        }
        let result: IconImageProcessor.Result = try XCTUnwrap(IconImageProcessor.processWide(b, maxSide: 500))
        XCTAssertEqual(result.bitmap.width, 500)
        XCTAssertEqual(result.bitmap.height, 100)
        // 背景は透明、帯は不透明
        XCTAssertGreaterThan(result.bitmap.alpha(250, 50), 200)
        let empty = IconBitmap(width: 10, height: 10)
        XCTAssertNil(IconImageProcessor.processWide(empty))
    }
}
