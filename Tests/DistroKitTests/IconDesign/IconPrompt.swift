import Foundation
@testable import DistroKit

/// アイコンの絵柄（ChatGPT に渡す決まり）。単色ならアプリが文字の色で塗り、色付きならそのまま出す（scripts/icon_pack.py が見分ける）。
enum IconStyle: String, CaseIterable, Sendable {
    /// 単色の線（プロ向けの編集アプリの道具バーと同じ。いちばんそろえやすい）
    case proLine
    /// 光るネオン管（暗い画面で映える）
    case neon
    /// 立体のガラス（大きなボタン向け）
    case glass3D
    /// 太いフラット（2 色）
    case boldDuotone

    var title: String {
        switch self {
        case .proLine: return "プロ・ライン（単色・おすすめ）"
        case .neon: return "ネオン（光る線・色付き）"
        case .glass3D: return "ガラス・立体（色付き）"
        case .boldDuotone: return "ボールド・2 色（色付き）"
        }
    }

    var detail: String {
        switch self {
        case .proLine: return "DaVinci Resolve や Final Cut Pro の道具バーのような細い線のアイコン。アプリが文字の色で塗るので、ダークとライトの両方で自然に見えます。"
        case .neon: return "オレンジ・マゼンタ・シアンに光る線。暗い画面で「カッコよさ」がいちばん出ます。"
        case .glass3D: return "半透明のガラスに光が当たったような立体。ホームの大きなボタンや AI の道具に向きます。"
        case .boldDuotone: return "太い塗りの形を 2 色で。小さくても見分けやすく、遊び心のある見た目になります。"
        }
    }

    var isMonochrome: Bool { return self == .proLine }

    /// ChatGPT に渡す絵柄の決まり（英語）。
    var styleRules: String {
        switch self {
        case .proLine:
            return """
            - Monoline glyphs in pure white (#FFFFFF) on a fully transparent background. No fills except tiny solid dots or small solid arrowheads.
            - Stroke width: exactly 2 px on a 24 px grid (= 1/12 of the icon box), uniform everywhere, rounded caps and rounded joins.
            - Corner radius 2 px on a 24 px grid for rectangles; circles are perfect circles.
            - Flat front view only. No perspective, no shadows, no gradients, no glow, no texture.
            - Visual weight like the toolbar icons of professional video editors (DaVinci Resolve, Final Cut Pro), but original drawings.
            """
        case .neon:
            return """
            - Glowing neon-tube line icons on a fully transparent background.
            - Tube colours from this palette only: hot orange #FF7A1A (main), magenta #FF3D9A, electric cyan #22D3EE, with white-hot cores.
            - Stroke equivalent to 2 px on a 24 px grid, rounded caps; soft outer glow that fades to fully transparent within 6% of the box.
            - Flat front view, no background panel, no reflections on a floor, no text.
            """
        case .glass3D:
            return """
            - Glossy 3D glass icons (glassmorphism) floating on a fully transparent background.
            - Frosted translucent glass bodies tinted with the palette: orange #FF7A1A, violet #7C5CFF, cyan #22D3EE; crisp white specular highlights, subtle inner glow.
            - Soft three-quarter top-left key light, consistent across every icon. Gentle contact shadow at most, no floor, no backdrop.
            - Chunky readable silhouettes; the shape must still read at 24 px.
            """
        case .boldDuotone:
            return """
            - Bold filled duotone icons on a fully transparent background.
            - Primary shape in hot orange #FF7A1A, secondary details in light grey #ECEEF2, small accents in near-black #15171B.
            - Rounded geometric shapes, 3 px corner radius on a 24 px grid, no outlines, no gradients, no shadows.
            - Strong silhouettes that stay readable at 20 px.
            """
        }
    }
}

/// 開発者が ChatGPT（画像生成）でアイコンを作るためのプロンプトと、その説明書（docs/アイコン制作プロンプト.md）。アプリには入らない。
enum IconPrompt {
    /// 最初に 1 回だけ貼る、全体の決まり（役割・絵柄・出力の形・してはいけないこと）。
    static func styleGuide(_ style: IconStyle) -> String {
        return """
        You are a senior product icon designer who builds icon systems for professional video-editing apps on iPad.
        We will design one coherent icon family for an original iPad video editor called "Distro VE" (dark, pro, premium; accent colour hot orange #FF7A1A).
        Keep every rule below for every image in this conversation, and keep the style identical from the first sheet to the last.

        STYLE
        \(style.styleRules)
        - Original artwork only. Do not imitate Apple SF Symbols, Material icons, or any brand logo (no YouTube, TikTok or Instagram marks).
        - No letters or words, except when the concept itself is a letter (for example the letter "A" for text tools).

        GRID AND COMPOSITION
        - Each icon is centred in its own cell (the whole image for a single icon), inside an invisible square as large as the cell's shorter side, with an even 8% padding on every side of that square; the artwork fills the square optically (circles slightly larger than squares). Never stretch an icon to the cell's shape.
        - Same line weight, corner radius, perspective and level of detail across all icons. Reuse a shared visual vocabulary: a "clip/frame" is a rounded rectangle, a "timeline" is a horizontal line with a small playhead, "AI" is a four-point sparkle.
        - Must stay readable at 20 px; avoid hairline details and tiny gaps.

        OUTPUT
        - PNG with a truly transparent background (alpha), sRGB. Never draw a background colour, tile, card, circle plate or frame behind an icon.
        - For a sheet: exactly the image size and the columns × rows of equal cells given in the sheet message. One icon per cell, in the given order (row by row, left to right). Every icon stays fully inside its own cell with clear empty space between neighbouring cells, all at the same size. Empty cells stay empty. No grid lines, no numbers, no captions.
        - For a single icon: one 1024x1024 image with only that icon.

        NEVER
        - No text labels, captions, numbers, watermarks or signatures.
        - No mockups, devices, hands or UI screenshots around the icons.
        - No drop shadows or glow unless the style above asks for them.

        Reply "Ready" and wait for the first sheet.
        """
    }

    /// シート 1 枚ぶん。index は 0 から。6 枚にまとめるときは 1 行ずつ並べて書く（48 個でも順番を間違えにくいように）。
    static func sheet(_ index: Int, style: IconStyle, layout: IconSheetLayout = .six) -> String {
        let sheets: [[IconSlot]] = IconCatalog.sheets(layout)
        guard index >= 0 && index < sheets.count else { return "" }
        let slots: [IconSlot] = sheets[index]
        let cellWidth: Int = layout.width / layout.columns
        let cellHeight: Int = layout.height / layout.rows
        var lines: [String] = []
        lines.append("Sheet \(index + 1) of \(sheets.count) — one \(layout.width)x\(layout.height) PNG with a transparent background, an exact grid of \(layout.columns) columns × \(layout.rows) rows of equal cells (each about \(cellWidth)×\(cellHeight) px). \(slots.count) icons in this exact order:")
        var row: Int = 0
        while row * layout.columns < slots.count {
            let start: Int = row * layout.columns
            let end: Int = min(slots.count, start + layout.columns)
            var cells: [String] = []
            for position in start..<end {
                cells.append("\(position + 1) [\(slots[position].id)] \(slots[position].prompt)")
            }
            lines.append("Row \(row + 1): " + cells.joined(separator: " · "))
            row += 1
        }
        let empty: Int = layout.capacity - slots.count
        if empty > 0 {
            lines.append("Leave the last \(empty) cell\(empty == 1 ? "" : "s") empty.")
        }
        lines.append("Same style as the previous sheets (\(style.rawValue)). Do not draw the numbers or the bracketed names.")
        return lines.joined(separator: "\n")
    }

    /// 1 つだけ作り直すとき。
    static func single(_ slot: IconSlot, style: IconStyle) -> String {
        return "Single icon [\(slot.id)] — \(slot.prompt). One 1024x1024 transparent PNG, centred with 8% padding, exactly the same style as the sheets (\(style.rawValue))."
    }

    /// アプリのアイコン（scripts/icon_pack.py が Assets の AppIcon にする）。
    static func appIcon(_ style: IconStyle) -> String {
        return """
        Design the iOS/iPadOS app icon for "Distro VE", an original pro video editor for iPad.
        - 1024x1024 PNG, square, full-bleed, NO transparency and NO rounded corners (iPadOS applies the mask itself).
        - Concept: a bold stylised film strip that bends into a forward "play" arrow, with a glowing hot-orange (#FF7A1A) edge, on a deep charcoal-to-black gradient with a hint of violet.
        - Matches the in-app icon family (\(style.rawValue)) but bolder and simpler; one strong silhouette, readable at 60 px.
        - Keep all important shapes inside the central 80% (safe area). No text, no letters, no brand logos.
        - Then make two variants with the same composition: (a) Dark appearance — the symbol on a transparent background; (b) Tinted — the symbol in pure white on a transparent background.
        """
    }

    /// ロゴ・背景・イラスト（アイコン以外）。
    static func brand(_ slot: IconSlot, style: IconStyle) -> String {
        switch slot.shape {
        case .wide:
            return "[\(slot.id)] \(slot.prompt). One 1536x1024 PNG with a fully transparent background; draw the emblem as one horizontal 3:1 shape across the middle and leave the rest empty (the empty space is trimmed afterwards). No text, same family as the icons (\(style.rawValue))."
        case .backdrop:
            return "[\(slot.id)] \(slot.prompt). One opaque 1536x1024 PNG. The app crops it to fill the iPad screen in both orientations, so keep the light in the centre and the centre calm. No text, no logos."
        case .appIcon:
            return appIcon(style)
        case .square:
            return "[\(slot.id)] An illustration: \(slot.prompt). 1024x1024 transparent PNG, centred with 10% padding, richer than an icon but in the same family (\(style.rawValue)). No text."
        }
    }

    // MARK: 説明書（docs/アイコン制作プロンプト.md）

    static func document() -> String {
        let six: [[IconSlot]] = IconCatalog.sheets(.six)
        let detailed: [[IconSlot]] = IconCatalog.sheets(.detailed)
        var out: [String] = []
        out.append("# アイコン制作プロンプト（開発者用・ChatGPT）")
        out.append("")
        out.append("> このファイルは `Tests/DistroKitTests/IconDesign/IconPrompt.swift` から作っています（テスト `IconPromptTests` が中身の一致を確かめます）。シートの並び順は `scripts/icon_layout.json` に書き出し、取り込みのスクリプト `scripts/icon_pack.py` が使います。")
        out.append("")
        out.append("Distro VE のボタン・道具・エフェクト・トランジションなど **\(IconCatalog.all.count) か所** の絵は、開発者が ChatGPT の画像生成で作り、アプリに入れて配布します。アプリを使う人が作ったり取り込んだりすることはありません。絵が入っていない所は SF Symbols が出ます。")
        out.append("")
        out.append("## 1. 流れ")
        out.append("")
        out.append("1. ChatGPT で新しいチャットを開き、「2. 全体の決まり」から絵柄を 1 つ選んで貼って送る（「Ready」と返ってくる）。")
        out.append("2. 「3. \(six.count) 枚の画像」の **画像 1** を送る → 48 個が並んだ横長の 1 枚ができる。絵柄が気に入らなければ、ここで直してもらう（例：「線をもう少し太く」）。")
        out.append("3. 同じチャットのまま、画像 2〜\(six.count) を順に送る（同じチャットだと絵柄がそろう）。続けて「4. アプリのアイコン」と「5. ロゴ・背景」も作る。")
        out.append("4. できた画像を、次の名前でリポジトリの `Design/Icons/` に置く。GitHub の **Add file > Upload files** なら iPad からも置けます。PNG・JPEG・WebP のどれでも読めます。")
        out.append("")
        out.append("   | 画像 | ファイル名 |")
        out.append("   | --- | --- |")
        out.append("   | 画像 1〜\(six.count) | `sheet-1.png` 〜 `sheet-\(six.count).png` |")
        out.append("   | アプリのアイコン | `app.icon.png`（ダーク用の `app.icon.dark.png`・色付け用の `app.icon.tinted.png` は無くてもよい） |")
        out.append("   | ホームのロゴ | `brand.logo.png` |")
        out.append("   | ホームの背景 | `brand.background.png` |")
        out.append("")
        out.append("5. `python3 scripts/icon_pack.py` を実行する（Pillow と numpy が要ります：`pip install pillow numpy`）。Claude Code に「アイコンを取り込んで」と頼んでも同じことをします。")
        out.append("   - シートを切り分け、背景を透明にし（白地・黒地・市松模様のどれでも）、余白を切り詰めて真ん中に同じ大きさでおさめ、単色か色付きかを見分けて、`DistroVE.swiftpm/Assets.xcassets` に書き出します。単色の絵はテンプレートになり、アプリが文字の色で塗ります。")
        out.append("   - `app.icon.png` があれば Assets の AppIcon を作り、`DistroVE.swiftpm/Package.swift` の `appIcon` を `.asset(\"AppIcon\")` にします。")
        out.append("6. `Design/Icons/preview.png`（確認用の一覧）で、順番の違い・欠け・はみ出しを確かめる。スクリプトも、絵が無いマス・空けるはずのマスに描かれた絵・マスの端に触れている絵を知らせます。")
        out.append("7. 直したい絵は「6. 1 つだけ作り直す」の文で作り、`Design/Icons/edit.split.png` のように名前を付けて置き、もう一度 5 を実行する。シートの中の同じ絵より、1 つずつ置いた絵が優先されます。")
        out.append("")
        out.append("1 枚に 48 個だと、ChatGPT が絵の数や順番を間違えることがあります。シートごと作り直すときは同じ番号でもう一度作るか、「7. 細かく作る」（1 枚に 16 個）を使ってください。")
        out.append("")
        out.append("## 2. 全体の決まり（最初に 1 回だけ貼る）")
        out.append("")
        out.append("絵柄を 1 つ選びます。迷ったら **プロ・ライン**（単色）がいちばんそろえやすく、アプリの色に自動で合います。")
        for style in IconStyle.allCases {
            out.append("")
            out.append("### \(style.title)")
            out.append("")
            out.append(style.detail)
            out.append("")
            out.append("```text")
            out.append(styleGuide(style))
            out.append("```")
        }
        out.append("")
        out.append("## 3. \(six.count) 枚の画像（1 枚に 8 列 × 6 行の 48 個）")
        out.append("")
        out.append("`[ ]` の中は絵の名前で、`scripts/icon_pack.py` はこの順番で切り分けます。下の例はプロ・ラインのとき。ほかの絵柄では最後の行の `(proLine)` を選んだ絵柄の名前（`neon` など）に変えます。")
        for index in 0..<six.count {
            out.append("")
            out.append("### 画像 \(index + 1)（`sheet-\(index + 1).png`。\(IconCatalog.sheetTitle(index, layout: .six))、\(six[index].count) 個）")
            out.append("")
            out.append("```text")
            out.append(sheet(index, style: .proLine, layout: .six))
            out.append("```")
        }
        out.append("")
        out.append("## 4. アプリのアイコン（`app.icon.png`）")
        out.append("")
        out.append("```text")
        out.append(appIcon(.proLine))
        out.append("```")
        out.append("")
        out.append("1 枚目を `app.icon.png`、ダーク用を `app.icon.dark.png`、色付け用を `app.icon.tinted.png` として置きます。透明な所があっても、アプリのアイコン（1 枚目）は黒で埋めます（iPadOS のアイコンは透明にできないため）。")
        out.append("")
        out.append("## 5. ロゴ・背景・イラスト")
        out.append("")
        out.append("ホームのロゴと背景は形が違うので、\(six.count) 枚とは別に 1 枚ずつ作ります（無くてもアプリは動きます）。はじめに（チュートリアル）の絵・プロジェクトが無いときの絵・書き出し完了の絵は画像 5 に入っています。もっと大きく描き込みたいときは、下の文で 1 枚ずつ作り直して同じ名前で置きます。")
        for slot in IconCatalog.slots(in: .brand) where slot.shape != .appIcon {
            out.append("")
            out.append("- **\(slot.title)**（`\(slot.fileName)`）")
            out.append("")
            out.append("  ```text")
            out.append("  " + brand(slot, style: .proLine))
            out.append("  ```")
        }
        out.append("")
        out.append("## 6. 1 つだけ作り直す")
        out.append("")
        out.append("`[ ]` と説明は「9. 全部の一覧」から選びます。できた画像は `Design/Icons/edit.split.png` のように名前を付けて置きます。")
        out.append("")
        out.append("```text")
        if let example = IconCatalog.slot("edit.split") {
            out.append(single(example, style: .proLine))
        }
        out.append("```")
        out.append("")
        out.append("## 7. 細かく作る（1 枚に 4 列 × 4 行の 16 個・\(detailed.count) 枚）")
        out.append("")
        out.append("1 つずつの絵をはっきりさせたいとき、またはシートの一部だけ作り直したいときに使います。`detailed-1.png` 〜 `detailed-\(detailed.count).png` の名前で置くと、\(six.count) 枚の画像の同じ絵より優先されます（全部作らなくてもかまいません）。")
        out.append("")
        out.append("<details>")
        out.append("<summary>\(detailed.count) 枚のプロンプト</summary>")
        for index in 0..<detailed.count {
            out.append("")
            out.append("#### `detailed-\(index + 1).png`（\(IconCatalog.sheetTitle(index, layout: .detailed))、\(detailed[index].count) 個）")
            out.append("")
            out.append("```text")
            out.append(sheet(index, style: .proLine, layout: .detailed))
            out.append("```")
        }
        out.append("")
        out.append("</details>")
        out.append("")
        out.append("## 8. 仕上がりの確認（プロの品質チェック）")
        out.append("")
        out.append("- [ ] 背景が透明（白い四角・タイル・影が付いていない）。付いていてもスクリプトが消しますが、透明のほうが縁がきれい。")
        out.append("- [ ] 線の太さ・角の丸み・余白が全部のシートで同じ（`preview.png` で見比べる）。")
        out.append("- [ ] 20pt（iPad の道具バーの大きさ）でも形が分かる（`preview.png` の右上の小さな絵で確かめる）。")
        out.append("- [ ] 文字・番号・名前が絵に入っていない（`[edit.split]` などを描いてしまったら作り直す）。")
        out.append("- [ ] 似た道具が見分けられる（削除とリップル削除、分割と無音カット、フェードと黒フェードなど）。")
        out.append("- [ ] 他社のロゴや SF Symbols をなぞっていない（YouTube・TikTok・Instagram のマークは使わない）。")
        out.append("- [ ] ダークとライトの両方で見る（単色はアプリが色を塗るので自動で合う。色付きは明るい背景でも沈まないか）。")
        out.append("")
        out.append("## 9. 全部の一覧")
        out.append("")
        out.append("| ファイル名 | 場所 | 今の SF Symbols | 描くもの |")
        out.append("| --- | --- | --- | --- |")
        for group in IconGroup.allCases {
            for slot in IconCatalog.slots(in: group) {
                out.append("| `\(slot.fileName)` | \(group.title)：\(slot.title) | `\(slot.fallback)` | \(slot.prompt) |")
            }
        }
        out.append("")
        return out.joined(separator: "\n")
    }
}
