import Foundation

/// アイコンの絵柄（ChatGPT に渡す決まり）。単色ならアプリが文字の色で塗り、色付きならそのまま出す（取り込むときに自動で見分ける）。
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

/// ChatGPT（画像生成）でアイコンを作るためのプロンプト。アプリの「設定 > アイコン」と docs/アイコン制作プロンプト.md は同じ文を使う。
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
        - Each icon is centred in its own square cell (the whole image for a single icon) with an even 8% padding on every side; the artwork fills the remaining square optically (circles slightly larger than squares).
        - Same line weight, corner radius, perspective and level of detail across all icons. Reuse a shared visual vocabulary: a "clip/frame" is a rounded rectangle, a "timeline" is a horizontal line with a small playhead, "AI" is a four-point sparkle.
        - Must stay readable at 20 px; avoid hairline details and tiny gaps.

        OUTPUT
        - PNG with a truly transparent background (alpha), sRGB. Never draw a background colour, tile, card, circle plate or frame behind an icon.
        - For a sheet: one 1024x1024 image with an exact 4x4 grid of equal cells, icons in the given order, left to right, top to bottom; empty cells stay empty; no grid lines, no numbers, no captions.
        - For a single icon: one 1024x1024 image with only that icon.

        NEVER
        - No text labels, captions, numbers, watermarks or signatures.
        - No mockups, devices, hands or UI screenshots around the icons.
        - No drop shadows or glow unless the style above asks for them.

        Reply "Ready" and wait for the first sheet.
        """
    }

    /// シート（4×4）1 枚ぶん。index は 0 から。
    static func sheet(_ index: Int, style: IconStyle) -> String {
        let sheets: [[IconSlot]] = IconCatalog.sheets
        guard index >= 0 && index < sheets.count else { return "" }
        var lines: [String] = []
        lines.append("Sheet \(index + 1) of \(sheets.count) — one 1024x1024 transparent PNG, 4x4 grid, \(sheets[index].count) icons in this exact order (left to right, top to bottom):")
        for (position, slot) in sheets[index].enumerated() {
            lines.append("\(position + 1). [\(slot.id)] \(slot.prompt)")
        }
        if sheets[index].count < IconCatalog.sheetSize {
            lines.append("Leave the remaining \(IconCatalog.sheetSize - sheets[index].count) cells at the end empty.")
        }
        lines.append("Keep exactly the same style as the previous sheets (\(style.rawValue)). Do not draw the bracketed names.")
        return lines.joined(separator: "\n")
    }

    /// 1 つだけ作り直すとき。
    static func single(_ slot: IconSlot, style: IconStyle) -> String {
        return "Single icon [\(slot.id)] — \(slot.prompt). One 1024x1024 transparent PNG, centred with 8% padding, exactly the same style as the sheets (\(style.rawValue))."
    }

    /// ChatGPT（コード実行）にシートを切り分けてもらうとき（アプリの「シートから切り出す」でもできる）。
    static func slicing(_ index: Int) -> String {
        let sheets: [[IconSlot]] = IconCatalog.sheets
        guard index >= 0 && index < sheets.count else { return "" }
        let names: String = sheets[index].map { $0.fileName }.joined(separator: ", ")
        return """
        Use Python on the sheet image you just made: split it into its 4x4 cells, remove any remaining background so it is transparent, trim empty margins, centre each icon on a 512x512 transparent canvas with 8% padding, and save the cells in reading order with these exact file names: \(names). Then give me one ZIP file named distrove-icons-sheet-\(index + 1).zip.
        """
    }

    /// アプリのアイコン（Swift Playgrounds の App Settings > App Icon、または Assets の AppIcon）。
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
            return "[\(slot.id)] \(slot.prompt). Transparent PNG, 1536x512 (3:1), no text, same family as the icons (\(style.rawValue))."
        case .backdrop:
            return "[\(slot.id)] \(slot.prompt). Opaque PNG, 2048x1536 (4:3, used on iPad in both orientations, keep the centre calm). No text, no logos."
        case .appIcon:
            return appIcon(style)
        case .square:
            return "[\(slot.id)] An illustration: \(slot.prompt). 1024x1024 transparent PNG, centred with 10% padding, richer than an icon but in the same family (\(style.rawValue)). No text."
        }
    }

    // MARK: 説明書（docs/アイコン制作プロンプト.md）

    static func document() -> String {
        var out: [String] = []
        out.append("# アイコン制作プロンプト（ChatGPT 用・プロ向け）")
        out.append("")
        out.append("> このファイルは `Core/Content/IconPrompt.swift` から作っています（テスト `IconPromptTests` が中身の一致を確かめます）。アプリの「設定 > アイコン」の「プロンプトをコピー」と同じ文です。")
        out.append("")
        out.append("Distro VE のボタン・道具・エフェクト・トランジションなど **\(IconCatalog.all.count) か所** の絵を、ChatGPT の画像生成で作って差し替えられます。作った画像はアプリの「設定 > アイコン」から取り込むだけで、ボタンの大きさ・色・ダーク/ライトに合わせて自動で表示されます（コードの変更は要りません）。取り込んでいないところは今までどおり SF Symbols が出ます。")
        out.append("")
        out.append("## 1. 流れ（いちばん早い方法）")
        out.append("")
        out.append("1. ChatGPT で新しいチャットを開き、下の「2. 全体の決まり」から好きな絵柄の 1 つを貼って送る（「Ready」と返ってくる）。")
        out.append("2. 「3. シート」の **シート 1** を貼って送る → 4×4 に並んだ 1 枚の画像ができる。絵柄が気に入らなければ、ここで直してもらう（例：「線をもう少し太く」）。")
        out.append("3. 同じチャットのまま、シート 2、3……と順に送る（同じチャットだと絵柄がそろう）。")
        out.append("4. できた画像を iPad に保存し、アプリの **設定 > アイコン > シートから切り出す** で、シートの番号を選んで取り込む。名前は自動で付きます。")
        out.append("   - または、ChatGPT に「4. 切り分けの依頼」を送ると、名前の付いた PNG を ZIP でくれます。ZIP は「ファイル」アプリでタップして展開し、**設定 > アイコン > 画像を取り込む** でフォルダーごと選びます。")
        out.append("5. アプリのアイコンは「5. アプリのアイコン」で作り、Swift Playgrounds の **App Settings > App Icon** で選ぶ。")
        out.append("")
        out.append("取り込むときに、アプリが自動で次のことをします：背景を透明にする（白地・黒地のどちらでも）、余白を切り詰めて真ん中に同じ大きさでおさめる、単色か色付きかを見分ける（単色はアプリの文字の色で塗り、色付きはそのまま出す）。ファイル名は `edit.split.png` のほか `edit_split.png`・`01_Edit-Split@2x.png`・SF Symbols の名前（`scissors.png`）でも受け付けます。")
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
        out.append("## 3. シート（4×4 で 1 枚ずつ）")
        out.append("")
        out.append("全部で \(IconCatalog.sheets.count) 枚です。`[ ]` の中がファイル名（拡張子なし）で、アプリの「シートから切り出す」はこの順番で名前を付けます。下の例はプロ・ラインのとき。ほかの絵柄では最後の行の `(proLine)` を選んだ絵柄の名前（`neon` など）に変えます。")
        for (index, sheet) in IconCatalog.sheets.enumerated() {
            var groups: [String] = []
            for slot in sheet where !groups.contains(slot.group.title) {
                groups.append(slot.group.title)
            }
            out.append("")
            out.append("### シート \(index + 1)（\(groups.joined(separator: "・"))）")
            out.append("")
            out.append("```text")
            out.append(IconPrompt.sheet(index, style: .proLine))
            out.append("```")
        }
        out.append("")
        out.append("## 4. 切り分けの依頼（ChatGPT のコード実行で ZIP にしてもらう）")
        out.append("")
        out.append("シートを作った直後に送ります（シート 1 の例。番号とファイル名はシートごとに変わります。アプリの「設定 > アイコン」からはシートごとの文をコピーできます）。")
        out.append("")
        out.append("```text")
        out.append(slicing(0))
        out.append("```")
        out.append("")
        out.append("## 5. アプリのアイコン")
        out.append("")
        out.append("```text")
        out.append(appIcon(.proLine))
        out.append("```")
        out.append("")
        out.append("設定のしかた：Swift Playgrounds でこのアプリ（DistroVE.swiftpm）を開き、左上の **App Settings** → **App Icon** → 作った 1024×1024 の画像を選ぶ。Xcode で開く場合は Assets の AppIcon の Any・Dark・Tinted に 3 枚を入れます。")
        out.append("")
        out.append("## 6. ロゴ・背景・イラスト")
        out.append("")
        out.append("ホームのロゴと背景、プロジェクトが無いときの絵、はじめに（チュートリアル）の 6 枚、書き出し完了の絵です。1 枚ずつ作り、ファイル名を `[ ]` の中の名前にして取り込みます。")
        for slot in IconCatalog.slots(in: .brand) where slot.shape != .appIcon {
            out.append("")
            out.append("- **\(slot.title)**（`\(slot.fileName)`）")
            out.append("")
            out.append("  ```text")
            out.append("  " + brand(slot, style: .proLine))
            out.append("  ```")
        }
        out.append("")
        out.append("## 7. 1 つだけ作り直す")
        out.append("")
        out.append("```text")
        if let example = IconCatalog.slot("edit.split") {
            out.append(single(example, style: .proLine))
        }
        out.append("```")
        out.append("")
        out.append("## 8. 仕上がりの確認（プロの品質チェック）")
        out.append("")
        out.append("- [ ] 背景が透明（白い四角・タイル・影が付いていない）。付いていてもアプリが消しますが、透明のほうが縁がきれい。")
        out.append("- [ ] 線の太さ・角の丸み・余白が全部のシートで同じ（シートを並べて見比べる）。")
        out.append("- [ ] 20pt（iPad の道具バーの大きさ）でも形が分かる。アプリの「設定 > アイコン」の一覧で小さく表示して確かめる。")
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
