import Foundation

/// アイコンの分類（設定の一覧と、ChatGPT で作るときのシートの単位）。
enum IconGroup: String, CaseIterable, Sendable {
    case brand
    case home
    case tools
    case editing
    case playback
    case timeline
    case media
    case ai
    case text
    case effects
    case transitions
    case animations
    case shapes
    case blend
    case object3D
    case audio
    case speed
    case export
    case status

    var title: String {
        switch self {
        case .brand: return "ロゴ・背景・イラスト"
        case .home: return "ホーム・プロジェクト"
        case .tools: return "下の道具バー"
        case .editing: return "クリップの編集"
        case .playback: return "再生"
        case .timeline: return "トラック"
        case .media: return "素材・録画"
        case .ai: return "AI"
        case .text: return "文字・字幕"
        case .effects: return "エフェクト"
        case .transitions: return "トランジション"
        case .animations: return "アニメーション"
        case .shapes: return "図形・マスク・収め方"
        case .blend: return "ブレンド"
        case .object3D: return "3D"
        case .audio: return "音声加工"
        case .speed: return "速度・コマの補間"
        case .export: return "書き出し"
        case .status: return "状態・通知"
        }
    }
}

/// 1 枚の画像に何個並べて作るか。
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

    var title: String {
        switch self {
        case .six: return "6 枚にまとめる（1 枚に 48 個）"
        case .detailed: return "細かく作る（1 枚に 16 個）"
        }
    }
}

/// 絵の形（アイコンは正方形、ロゴや背景は形が違う）。
enum IconShape: String, Sendable {
    case square
    /// 横長（ロゴ 3:1）
    case wide
    /// 画面いっぱいの背景（縦横どちらにも使う。4:3）
    case backdrop
    /// アプリのアイコン（1024×1024、角を丸めない、透明なし）
    case appIcon
}

/// アプリの中の 1 つのアイコンの置き場所。取り込んだ画像（id と同じ名前のファイル）があればそれを、無ければ SF Symbols の fallback を出す。
struct IconSlot: Hashable, Sendable {
    /// ファイル名（拡張子なし）。例 "edit.split" → edit.split.png
    let id: String
    /// 取り込んだ画像が無いときの SF Symbols の名前
    let fallback: String
    let group: IconGroup
    /// 日本語の名前（設定の一覧に出す）
    let title: String
    /// 画像を作る AI への説明（英語。何を描くか）
    let prompt: String
    var shape: IconShape = .square

    var fileName: String { return id + ".png" }
}

/// 差し替えられるアイコンの一覧（Q63・アイコン制作プロンプト）。UI はこの id で絵を求める。
enum IconCatalog {
    static let all: [IconSlot] = {
        var result: [IconSlot] = []
        result += brand()
        result += home()
        result += tools()
        result += editing()
        result += playback()
        result += timeline()
        result += media()
        result += ai()
        result += text()
        result += effects()
        result += transitions()
        result += animations()
        result += shapes()
        result += blend()
        result += object3D()
        result += audio()
        result += speed()
        result += export()
        result += status()
        return result
    }()

    static let byID: [String: IconSlot] = {
        var map: [String: IconSlot] = [:]
        for slot in all { map[slot.id] = slot }
        return map
    }()

    /// ファイル名を比べるための形（大文字小文字・記号の違いを無視する）。
    private static let byKey: [String: String] = {
        var map: [String: String] = [:]
        for slot in all { map[key(slot.id)] = slot.id }
        return map
    }()

    static func slot(_ id: String) -> IconSlot? {
        return byID[id]
    }

    /// 取り込んだ画像が無いときの SF Symbols（一覧に無い id は、そのまま SF Symbols の名前として扱う）。
    static func fallback(for id: String) -> String {
        return byID[id]?.fallback ?? id
    }

    /// 画像のファイル名から id を探す。「01_edit_split@2x.png」「Edit-Split.PNG」なども edit.split とみなす。
    static func id(forFileName name: String) -> String? {
        var base: String = name
        if let dot = base.lastIndex(of: "."), ["png", "jpg", "jpeg", "heic", "webp", "tif", "tiff"].contains(base[base.index(after: dot)...].lowercased()) {
            base = String(base[..<dot])
        }
        for suffix in ["@2x", "@3x", "@1x"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        // 先頭の番号（01_ や 1- など）
        var trimmed: Substring = Substring(base)
        while let first = trimmed.first, first.isNumber { trimmed = trimmed.dropFirst() }
        if trimmed.count < base.count, let first = trimmed.first, first == "_" || first == "-" || first == " " || first == "." {
            base = String(trimmed.dropFirst())
        }
        if let direct = byID[base] { return direct.id }
        if let found = byKey[key(base)] { return found }
        // 「SF Symbols の名前」で作ったファイルも受け付ける（その記号を使う最初の置き場所）
        for slot in all where key(slot.fallback) == key(base) {
            return slot.id
        }
        return nil
    }

    static func key(_ text: String) -> String {
        var result: String = ""
        for scalar in text.lowercased().unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    static func slots(in group: IconGroup) -> [IconSlot] {
        return all.filter { $0.group == group }
    }

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

    // MARK: 一覧

    private static func s(_ id: String, _ fallback: String, _ group: IconGroup, _ title: String, _ prompt: String) -> IconSlot {
        return IconSlot(id: id, fallback: fallback, group: group, title: title, prompt: prompt)
    }

    private static func brand() -> [IconSlot] {
        var logo = s("brand.logo", "film.stack", .brand, "ホームのロゴ（横長）",
                     "a horizontal wordmark-free logo emblem for a video editor: a stylised film strip forming a play arrow, 3:1 wide")
        logo.shape = .wide
        var backdrop = s("brand.background", "rectangle.fill", .brand, "ホームの背景",
                         "a dark, subtle, premium backdrop: soft orange and violet light streaks on near-black, lots of empty space, no objects")
        backdrop.shape = .backdrop
        var app = s("app.icon", "film.stack", .brand, "アプリのアイコン",
                    "the app icon: a bold film-strip play arrow with a glowing orange edge on a deep charcoal gradient")
        app.shape = .appIcon
        let list: [IconSlot] = [
            app, logo, backdrop,
            s("illustration.empty", "film.stack", .brand, "プロジェクトが無いときの絵", "an empty clapperboard with a small sparkle, inviting the user to start"),
            s("illustration.exported", "checkmark.circle.fill", .brand, "書き出し完了の絵", "a finished film reel with a check mark and confetti"),
            s("onboarding.welcome", "film.stack", .brand, "はじめに：ようこそ", "a stack of film frames with a friendly sparkle"),
            s("onboarding.media", "plus.rectangle.on.rectangle", .brand, "はじめに：素材を追加", "photos and video frames flying into a timeline"),
            s("onboarding.timeline", "hand.draw", .brand, "はじめに：タイムライン", "a hand dragging a clip on a timeline with a playhead"),
            s("onboarding.keyframes", "diamond", .brand, "はじめに：キーフレーム", "keyframe diamonds on a curve with motion"),
            s("onboarding.ai", "wand.and.stars", .brand, "はじめに：AI と自動編集", "a magic wand over a waveform and subtitles"),
            s("onboarding.export", "square.and.arrow.up", .brand, "はじめに：書き出し", "a video frame launching upward with an arrow")
        ]
        return list
    }

    private static func home() -> [IconSlot] {
        let list: [IconSlot] = [
            s("home.new", "plus", .home, "新規プロジェクト", "a big plus sign inside a film frame"),
            s("home.templates", "square.grid.2x2", .home, "テンプレート", "a 2x2 grid of layout tiles"),
            s("home.open", "folder", .home, ".disve を開く", "an open folder with a film frame peeking out"),
            s("home.help", "questionmark.circle", .home, "ヘルプ", "a question mark in a circle"),
            s("home.settings", "gearshape", .home, "設定", "a gear"),
            s("project.open", "square.and.pencil", .home, "開く", "a pencil writing on a frame"),
            s("project.rename", "pencil", .home, "名前の変更", "a pencil over a text line"),
            s("project.duplicate", "plus.square.on.square", .home, "複製", "two overlapping squares with a plus"),
            s("project.share", "square.and.arrow.up", .home, "共有", "a box with an arrow going up"),
            s("project.restore", "clock.arrow.circlepath", .home, "バックアップから戻す", "a clock with a circular arrow going back in time"),
            s("project.delete", "trash", .home, "削除", "a trash can"),
            s("project.recovered", "exclamationmark.arrow.circlepath", .home, "前回の続き", "a circular arrow with an exclamation mark"),
            s("template.portrait", "rectangle.portrait", .home, "縦のテンプレート", "a tall 9:16 frame"),
            s("template.landscape", "rectangle", .home, "横のテンプレート", "a wide 16:9 frame"),
            s("template.selected", "checkmark.circle.fill", .home, "選んだテンプレート", "a solid check mark badge"),
            s("project.placeholder", "film", .home, "サムネイルの無いプロジェクト", "a film strip placeholder"),
            s("editor.home", "chevron.left", .home, "ホームへ戻る", "a left chevron"),
            s("editor.redo", "arrow.uturn.forward", .home, "やり直す", "a curved arrow turning forward"),
            s("editor.undo", "arrow.uturn.backward", .home, "元に戻す", "a curved arrow turning back"),
            s("editor.save", "square.and.arrow.down", .home, "保存", "a box with an arrow going down"),
            s("editor.export", "square.and.arrow.up.on.square", .home, "書き出しへ", "a stack of frames with an arrow going up")
        ]
        return list
    }

    private static func tools() -> [IconSlot] {
        let prompts: [String: String] = [
            "media": "two stacked photo/video frames with a plus badge",
            "audio": "a music note with a short waveform",
            "text": "a bold capital T with a text cursor",
            "stickers": "a smiling sticker with a peeled corner",
            "object3D": "an isometric cube with highlighted edges",
            "subtitles": "a speech bubble with two subtitle lines",
            "ai": "a magic wand with sparkles",
            "split": "scissors cutting a film strip",
            "filter": "three overlapping colour circles like camera filters",
            "canvas": "a frame with aspect-ratio corner marks",
            "drawing": "a pen tip drawing a squiggle",
            "marker": "a bookmark flag on a timeline",
            "reorder": "three stacked bars with up/down arrows"
        ]
        var list: [IconSlot] = []
        for tool in RootTool.allCases {
            list.append(s("tool." + tool.rawValue, tool.symbol, .tools, tool.title, prompts[tool.rawValue] ?? tool.title))
        }
        return list
    }

    private static func editing() -> [IconSlot] {
        let list: [IconSlot] = [
            s("edit.keyframe", "diamond", .editing, "キーフレーム", "a keyframe diamond on a timeline line"),
            s("edit.split", "scissors", .editing, "分割", "scissors cutting through a clip"),
            s("edit.delete", "trash", .editing, "削除", "a trash can"),
            s("edit.rippleDelete", "arrow.left.to.line", .editing, "リップル削除", "a clip removed with the following clips sliding left to close the gap"),
            s("edit.duplicate", "plus.square.on.square", .editing, "複製", "two overlapping clips with a plus"),
            s("edit.speed", "speedometer", .editing, "速度", "a speedometer gauge"),
            s("edit.volume", "speaker.wave.2", .editing, "音量", "a speaker with sound waves"),
            s("edit.audioFX", "waveform", .editing, "音声加工", "an audio waveform with a small slider"),
            s("edit.reverse", "backward", .editing, "逆再生", "double arrows pointing backward over a film frame"),
            s("edit.freeze", "pause.rectangle", .editing, "静止", "a frame with a pause sign and a snowflake hint"),
            s("edit.transition", "rectangle.2.swap", .editing, "トランジション", "two frames swapping with a crossing arrow"),
            s("edit.text", "character.cursor.ibeam", .editing, "文字の編集", "a letter A with an I-beam text cursor"),
            s("edit.transform", "arrow.up.left.and.arrow.down.right", .editing, "変形", "a frame with diagonal resize arrows"),
            s("edit.animation", "sparkles", .editing, "アニメ", "sparkles with motion lines"),
            s("edit.effects", "wand.and.rays", .editing, "エフェクト", "a wand emitting rays"),
            s("edit.blend", "square.stack.3d.down.right", .editing, "ブレンド", "stacked translucent layers"),
            s("edit.object3D", "cube", .editing, "3D", "an isometric cube"),
            s("edit.beats", "metronome", .editing, "ビート検出", "a metronome"),
            s("edit.adjust", "slider.horizontal.3", .editing, "調整", "three horizontal sliders"),
            s("edit.filters", "camera.filters", .editing, "フィルター", "three overlapping colour circles"),
            s("edit.mask", "circle.dashed", .editing, "マスク・範囲", "a dashed circle cut-out over a frame"),
            s("edit.chromaKey", "person.crop.square.filled.and.at.rectangle", .editing, "クロマキー", "a person silhouette in front of a green screen"),
            s("edit.deselect", "xmark", .editing, "選択解除", "an X mark"),
            s("edit.subtitle", "captions.bubble", .editing, "字幕を編集", "a speech bubble with subtitle lines and a pencil"),
            s("edit.flipHorizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right", .editing, "左右反転", "two mirrored triangles with a horizontal double arrow"),
            s("edit.flipVertical", "arrow.up.and.down.righttriangle.up.righttriangle.down", .editing, "上下反転", "two mirrored triangles with a vertical double arrow"),
            s("param.key", "diamond", .editing, "キーフレーム（なし）", "an outlined keyframe diamond"),
            s("param.key.animated", "diamond.bottomhalf.filled", .editing, "キーフレーム（動いている）", "a half-filled keyframe diamond"),
            s("param.key.on", "diamond.fill", .editing, "キーフレーム（この時刻）", "a solid keyframe diamond"),
            s("param.reset", "arrow.uturn.backward", .editing, "値を戻す", "a small curved arrow returning to the start"),
            s("keyframe.delete", "trash", .editing, "キーフレームを消す", "a trash can with a small diamond"),
            s("effect.remove", "trash", .editing, "エフェクトを外す", "a wand with a small minus sign")
        ]
        return list
    }

    private static func playback() -> [IconSlot] {
        let list: [IconSlot] = [
            s("playback.play", "play.fill", .playback, "再生", "a solid play triangle"),
            s("playback.pause", "pause.fill", .playback, "一時停止", "two solid pause bars"),
            s("playback.previousFrame", "backward.frame", .playback, "1 コマ戻る", "a step-back arrow against a frame line"),
            s("playback.nextFrame", "forward.frame", .playback, "1 コマ進む", "a step-forward arrow against a frame line"),
            s("playback.loop", "repeat", .playback, "くり返し再生", "two arrows forming a loop"),
            s("playback.range", "arrow.left.and.right", .playback, "範囲を再生", "a horizontal double arrow between two brackets"),
            s("playback.rangeOn", "arrow.left.and.right.square.fill", .playback, "範囲の再生中", "a filled square with a horizontal double arrow"),
            s("playback.quality", "dial.medium", .playback, "プレビューの画質", "a dial knob set to medium"),
            s("playback.thermal", "thermometer.high", .playback, "端末が熱い", "a thermometer with a high level")
        ]
        return list
    }

    private static func timeline() -> [IconSlot] {
        let list: [IconSlot] = [
            s("track.visible", "eye", .timeline, "表示", "an open eye"),
            s("track.hidden", "eye.slash", .timeline, "非表示", "an eye with a slash"),
            s("track.sound", "speaker.wave.2", .timeline, "音あり", "a speaker with waves"),
            s("track.muted", "speaker.slash", .timeline, "消音", "a speaker with a slash"),
            s("track.locked", "lock", .timeline, "ロック", "a closed padlock"),
            s("track.unlocked", "lock.open", .timeline, "ロック解除", "an open padlock"),
            s("track.captions", "captions.bubble", .timeline, "字幕トラック", "a speech bubble with subtitle lines")
        ]
        return list
    }

    private static func media() -> [IconSlot] {
        let list: [IconSlot] = [
            s("media.photos", "photo.on.rectangle", .media, "写真ライブラリ", "stacked photos with a small mountain picture"),
            s("media.files", "folder", .media, "ファイル・クラウド", "a folder with a small cloud"),
            s("media.camera", "video", .media, "カメラで撮影", "a video camera"),
            s("media.narration", "mic", .media, "ナレーション", "a studio microphone"),
            s("media.screenRecord", "record.circle", .media, "画面録画", "a record dot inside a circle"),
            s("media.screenRecordStop", "stop.circle", .media, "画面録画を止める", "a stop square inside a circle"),
            s("media.cameraSwitch", "camera.rotate", .media, "カメラの切り替え", "a camera with rotating arrows"),
            s("media.video", "film", .media, "動画", "a film strip"),
            s("media.audio", "music.note", .media, "音声", "a music note"),
            s("media.image", "photo", .media, "画像", "a photo with a mountain and sun"),
            s("media.gif", "photo.stack", .media, "GIF", "a stack of photos suggesting animation"),
            s("media.model3D", "cube", .media, "3D モデル", "an isometric cube with a small vertex dot"),
            s("sound.play", "play.circle", .media, "試聴", "a play triangle in a circle"),
            s("sound.stop", "stop.circle.fill", .media, "試聴を止める", "a solid stop square in a filled circle"),
            s("media.mosaic", "square.grid.3x3", .media, "モザイク枠", "a pixelated 3x3 mosaic block"),
            s("media.draw", "pencil.tip.crop.circle", .media, "手書き", "a pen tip in a circle"),
            s("media.add", "plus.circle", .media, "タイムラインに追加", "a plus in a circle over a timeline line"),
            s("reorder.up", "chevron.up", .media, "並べ替え：上へ", "an up chevron above a list row"),
            s("reorder.down", "chevron.down", .media, "並べ替え：下へ", "a down chevron below a list row")
        ]
        return list
    }

    private static func ai() -> [IconSlot] {
        let list: [IconSlot] = [
            s("ai.captions", "captions.bubble", .ai, "自動字幕", "a speech bubble with subtitle lines and a sparkle"),
            s("ai.removeBackground", "person.crop.rectangle", .ai, "背景除去", "a person silhouette lifted out of a frame"),
            s("ai.silenceCut", "scissors.badge.ellipsis", .ai, "無音カット", "scissors cutting out a flat silent part of a waveform"),
            s("ai.beatEdit", "metronome", .ai, "BGM に合わせて自動編集", "a metronome with cut marks on beats"),
            s("ai.highlights", "star", .ai, "ハイライト抽出", "a star over a peak in a waveform"),
            s("ai.shorts", "rectangle.portrait", .ai, "ショート動画に変換", "a wide frame turning into a tall 9:16 frame"),
            s("ai.stabilize", "camera.metering.center.weighted", .ai, "手ぶれ補正", "a camera viewfinder with steady crosshair and shake lines removed"),
            s("ai.beatDetect", "waveform.path", .ai, "ビート検出", "a waveform with beat markers"),
            s("ai.loudness", "speaker.wave.3", .ai, "音量の自動そろえ", "a speaker with even-level bars"),
            s("ai.speakers", "person.2.wave.2", .ai, "話者の判別", "two people with sound waves"),
            s("ai.transcribe", "waveform.badge.mic", .ai, "文字起こし", "a microphone with a waveform badge")
        ]
        return list
    }

    private static func text() -> [IconSlot] {
        var list: [IconSlot] = [
            s("text.font", "textformat", .text, "フォント", "the letters Aa"),
            s("text.addCue", "plus", .text, "字幕を追加", "a plus next to a subtitle line"),
            s("text.importSRT", "square.and.arrow.down", .text, "SRT 読み込み", "a document with subtitle lines and a down arrow"),
            s("text.exportSRT", "square.and.arrow.up", .text, "SRT 書き出し", "a document with subtitle lines and an up arrow"),
            s("text.translate", "globe", .text, "翻訳", "a globe with two speech bubbles")
        ]
        let prompts: [String: String] = [
            "none": "a plain letter A without motion",
            "fade": "a letter A fading from transparent to solid",
            "typewriter": "letters appearing one by one with a cursor",
            "pop": "a letter A popping out with a burst",
            "slideUp": "a letter A rising from below with motion lines",
            "bounce": "a letter A bouncing on a line",
            "glitch": "a letter A split into shifted RGB slices",
            "blurIn": "a blurred letter A becoming sharp"
        ]
        let symbols: [String: String] = [
            "none": "textformat", "fade": "circle.lefthalf.filled", "typewriter": "keyboard", "pop": "sparkle",
            "slideUp": "arrow.up", "bounce": "arrow.up.and.down", "glitch": "waveform.path.ecg", "blurIn": "drop"
        ]
        for kind in TextAnimation.allCases {
            list.append(s("textAnim." + kind.rawValue, symbols[kind.rawValue] ?? "textformat", .text, "文字の動き：" + kind.label,
                          prompts[kind.rawValue] ?? kind.label))
        }
        return list
    }

    private static func effects() -> [IconSlot] {
        let prompts: [String: String] = [
            "blur": "a soft blurred dot",
            "mosaic": "a pixelated mosaic square",
            "glitch": "a frame broken into shifted horizontal slices",
            "rgbSplit": "three offset red, green and blue outlines",
            "vhs": "a cassette tape with scan lines",
            "vignette": "a frame with darkened corners",
            "shake": "a frame with shake motion lines",
            "flash": "a lightning bolt with a white burst",
            "zoomPulse": "a magnifier with pulsing rings",
            "grain": "a square full of film grain dots",
            "sharpen": "a sharp triangle with crisp edge lines",
            "bloom": "a sun with a soft glow halo",
            "zoomBlur": "radial zoom streaks from the centre",
            "mono": "a circle half black, half white",
            "invert": "a circle with inverted halves and a swap arrow",
            "posterize": "a gradient broken into flat colour steps",
            "kaleidoscope": "a symmetric hexagonal kaleidoscope pattern",
            "mirror": "a frame split in two mirrored halves"
        ]
        var list: [IconSlot] = []
        for kind in EffectKind.allCases {
            list.append(s(kind.iconID, kind.symbol, .effects, kind.label, prompts[kind.rawValue] ?? kind.label))
        }
        return list
    }

    private static func transitions() -> [IconSlot] {
        let symbols: [String: String] = [
            "fade": "circle.righthalf.filled", "fadeBlack": "moon.fill", "flashWhite": "sun.max.fill",
            "slideLeft": "arrow.left.square", "slideRight": "arrow.right.square", "slideUp": "arrow.up.square", "slideDown": "arrow.down.square",
            "wipeLeft": "rectangle.lefthalf.inset.filled", "wipeRight": "rectangle.righthalf.inset.filled",
            "wipeUp": "rectangle.tophalf.inset.filled", "wipeDown": "rectangle.bottomhalf.inset.filled",
            "zoomIn": "plus.magnifyingglass", "zoomOut": "minus.magnifyingglass", "blur": "drop", "glitch": "waveform.path.ecg",
            "spin": "arrow.triangle.2.circlepath", "flip3D": "arrow.left.and.right.righttriangle.left.righttriangle.right", "cube3D": "cube.transparent",
            "smoothCut": "arrow.triangle.merge"
        ]
        let prompts: [String: String] = [
            "fade": "two frames cross-dissolving into each other",
            "fadeBlack": "a frame fading into black and out again",
            "flashWhite": "a white flash burst between two frames",
            "slideLeft": "a frame sliding out to the left",
            "slideRight": "a frame sliding out to the right",
            "slideUp": "a frame sliding upward",
            "slideDown": "a frame sliding downward",
            "wipeLeft": "a straight wipe edge moving left across a frame",
            "wipeRight": "a straight wipe edge moving right across a frame",
            "wipeUp": "a straight wipe edge moving up across a frame",
            "wipeDown": "a straight wipe edge moving down across a frame",
            "zoomIn": "a frame zooming toward the viewer",
            "zoomOut": "a frame zooming away from the viewer",
            "blur": "two frames blurring together",
            "glitch": "two frames meeting in glitch slices",
            "spin": "a frame spinning with a circular arrow",
            "flip3D": "a card flipping in 3D",
            "cube3D": "a 3D cube rotating to the next face",
            "smoothCut": "two nearly identical frames morphing smoothly into one with flowing motion lines"
        ]
        var list: [IconSlot] = []
        for kind in TransitionKind.allCases {
            list.append(s(kind.iconID, symbols[kind.rawValue] ?? "rectangle.2.swap", .transitions, kind.label, prompts[kind.rawValue] ?? kind.label))
        }
        return list
    }

    private static func animations() -> [IconSlot] {
        let symbols: [String: String] = [
            "fade": "circle.lefthalf.filled", "slideLeft": "arrow.right", "slideRight": "arrow.left", "slideUp": "arrow.up",
            "slideDown": "arrow.down", "zoom": "plus.magnifyingglass", "pop": "sparkle", "spin": "arrow.clockwise", "blur": "drop"
        ]
        let prompts: [String: String] = [
            "fade": "a card fading in",
            "slideLeft": "a card entering from the left with motion lines",
            "slideRight": "a card entering from the right with motion lines",
            "slideUp": "a card rising from the bottom",
            "slideDown": "a card dropping from the top",
            "zoom": "a card growing from the centre",
            "pop": "a card popping in with an overshoot burst",
            "spin": "a card spinning in",
            "blur": "a blurred card becoming sharp"
        ]
        var list: [IconSlot] = [s("anim.none", "nosign", .animations, "動きなし", "a card with no motion and a small slash circle")]
        for kind in AnimationKind.allCases {
            list.append(s(kind.iconID, symbols[kind.rawValue] ?? "sparkles", .animations, kind.label, prompts[kind.rawValue] ?? kind.label))
        }
        return list
    }

    private static func shapes() -> [IconSlot] {
        let shapeSymbols: [String: String] = [
            "rectangle": "rectangle", "roundedRectangle": "app", "ellipse": "circle", "triangle": "triangle",
            "star": "star", "arrow": "arrow.right", "line": "line.diagonal"
        ]
        let shapePrompts: [String: String] = [
            "rectangle": "a plain outlined rectangle",
            "roundedRectangle": "an outlined rectangle with generously rounded corners",
            "ellipse": "an outlined horizontal oval",
            "triangle": "an outlined equilateral triangle",
            "star": "an outlined five-point star",
            "arrow": "an outlined right-pointing block arrow",
            "line": "a single diagonal straight line with a round dot at each end"
        ]
        var list: [IconSlot] = []
        for kind in ShapeKind.allCases {
            list.append(s(kind.iconID, shapeSymbols[kind.rawValue] ?? "square.on.circle", .shapes, "図形：" + kind.label,
                          shapePrompts[kind.rawValue] ?? "a simple outlined shape"))
        }
        let maskSymbols: [String: String] = ["rectangle": "rectangle.dashed", "ellipse": "circle.dashed", "linear": "line.diagonal", "mirror": "rectangle.split.1x2"]
        let maskPrompts: [String: String] = [
            "rectangle": "a dashed rectangle mask over a frame",
            "ellipse": "a dashed oval mask over a frame",
            "linear": "a frame split by a soft diagonal line",
            "mirror": "a horizontal band mask across a frame"
        ]
        list.append(s("mask.none", "nosign", .shapes, "マスクなし", "a frame with no mask and a small slash circle"))
        for kind in MaskShape.allCases {
            list.append(s(kind.iconID, maskSymbols[kind.rawValue] ?? "circle.dashed", .shapes, "マスク：" + kind.label,
                          maskPrompts[kind.rawValue] ?? kind.label))
        }
        let fitSymbols: [String: String] = ["fit": "rectangle.inset.filled", "fill": "rectangle.fill", "stretch": "arrow.left.and.right.square"]
        let fitPrompts: [String: String] = [
            "fit": "a picture fitted inside a frame with bars",
            "fill": "a picture filling the whole frame, edges cropped",
            "stretch": "a picture stretched sideways to the frame"
        ]
        for mode in FitMode.allCases {
            list.append(s(mode.iconID, fitSymbols[mode.rawValue] ?? "rectangle", .shapes, "収め方：" + mode.label, fitPrompts[mode.rawValue] ?? mode.label))
        }
        let aspectSymbols: [String: String] = [
            "landscape16x9": "rectangle", "portrait9x16": "rectangle.portrait", "square1x1": "square",
            "portrait4x5": "rectangle.portrait", "landscape4x3": "rectangle", "cinema21x9": "rectangle.ratio.16.to.9"
        ]
        let aspectPrompts: [String: String] = [
            "landscape16x9": "a wide empty frame in 16:9 proportions with small corner marks",
            "portrait9x16": "a tall empty frame in 9:16 proportions like a phone screen, with small corner marks",
            "square1x1": "an empty square frame with small corner marks",
            "portrait4x5": "a slightly tall empty frame in 4:5 proportions with small corner marks",
            "landscape4x3": "a classic empty frame in 4:3 proportions with small corner marks",
            "cinema21x9": "a very wide empty cinema frame in 21:9 proportions with small corner marks"
        ]
        for aspect in AspectPreset.allCases {
            list.append(s(aspect.iconID, aspectSymbols[aspect.rawValue] ?? "aspectratio", .shapes, "画面の形：" + aspect.label,
                          aspectPrompts[aspect.rawValue] ?? "an empty frame with small corner marks"))
        }
        return list
    }

    private static func blend() -> [IconSlot] {
        // どれも「重なった 2 つの円」でそろえ、重なりの中の印で見分ける
        let prompts: [String: String] = [
            "normal": "two overlapping circles, the front circle opaque and hiding the back one",
            "multiply": "two overlapping circles with the overlap filled with dense diagonal hatching (darker)",
            "screen": "two overlapping circles with the overlap open and small light rays around it (lighter)",
            "overlay": "two overlapping circles with the overlap split into a hatched half and an open half (contrast)",
            "darken": "two overlapping circles with a small down arrow inside the overlap",
            "lighten": "two overlapping circles with a small up arrow inside the overlap",
            "colorDodge": "two overlapping circles with a tiny sun burst inside the overlap",
            "colorBurn": "two overlapping circles with a tiny flame inside the overlap",
            "softLight": "two overlapping circles with a soft dotted overlap",
            "hardLight": "two overlapping circles with a small sharp lightning bolt inside the overlap",
            "difference": "two overlapping circles with a minus sign inside the overlap",
            "exclusion": "two overlapping circles with the overlap cut out and left empty",
            "add": "two overlapping circles with a plus sign inside the overlap",
            "hue": "two overlapping circles with a tiny segmented colour wheel inside the overlap",
            "saturation": "two overlapping circles with a tiny three-step intensity bar inside the overlap",
            "color": "two overlapping circles with a tiny paint drop inside the overlap",
            "luminosity": "two overlapping circles with a tiny half-solid, half-open dot inside the overlap"
        ]
        var list: [IconSlot] = []
        for mode in LayerBlend.allCases {
            list.append(s(mode.iconID, "square.stack.3d.down.right", .blend, "ブレンド：" + mode.label,
                          prompts[mode.rawValue] ?? "two overlapping circles"))
        }
        return list
    }

    private static func object3D() -> [IconSlot] {
        let prompts: [String: String] = [
            "text": "an extruded 3D letter A",
            "model": "a 3D model wireframe with an AR bracket",
            "cube": "a shaded 3D cube",
            "sphere": "a shaded 3D sphere",
            "cylinder": "a shaded 3D cylinder",
            "cone": "a shaded 3D cone",
            "torus": "a shaded 3D torus (donut)"
        ]
        var list: [IconSlot] = []
        for kind in Object3DKind.allCases {
            list.append(s(kind.iconID, kind.symbol, .object3D, "3D：" + kind.label, prompts[kind.rawValue] ?? kind.label))
        }
        let lightSymbols: [String: String] = [
            "studio": "light.max", "soft": "cloud.sun", "dramatic": "theatermasks", "sunset": "sunset", "neon": "lightbulb", "backlit": "sun.horizon"
        ]
        let lightPrompts: [String: String] = [
            "studio": "a sphere lit by two small softbox panels from the upper left and upper right",
            "soft": "a sphere with a wide soft highlight and a small cloud above it",
            "dramatic": "a sphere lit hard from one side, the other half in hatched shadow",
            "sunset": "a sphere lit low from the side by a half sun on a horizon line",
            "neon": "a sphere inside a glowing ring-shaped tube light",
            "backlit": "a sphere with a light source behind it and a bright rim around its edge"
        ]
        for light in Lighting3D.allCases {
            list.append(s(light.iconID, lightSymbols[light.rawValue] ?? "lightbulb", .object3D, "照明：" + light.label,
                          lightPrompts[light.rawValue] ?? "a lit sphere"))
        }
        let motionSymbols: [String: String] = [
            "none": "nosign", "spin": "arrow.triangle.2.circlepath", "flip": "arrow.up.arrow.down", "swing": "arrow.left.and.right",
            "float": "cloud", "tumble": "arrow.3.trianglepath"
        ]
        let motionPrompts: [String: String] = [
            "none": "a still cube with a small slash circle (no motion)",
            "spin": "a cube with a circular arrow around its vertical axis",
            "flip": "a cube with a curved arrow flipping it over its horizontal axis",
            "swing": "a cube hanging from a pivot point with a curved arrow swinging left and right",
            "float": "a cube hovering above a short shadow line with small up and down arrows",
            "tumble": "a tilted cube with two crossing curved arrows, rolling in several directions"
        ]
        for motion in Motion3D.allCases {
            list.append(s(motion.iconID, motionSymbols[motion.rawValue] ?? "rotate.3d", .object3D, "3D の動き：" + motion.label,
                          motionPrompts[motion.rawValue] ?? "a moving cube with arrows"))
        }
        return list
    }

    private static func audio() -> [IconSlot] {
        let eqSymbols: [String: String] = [
            "flat": "slider.horizontal.below.rectangle", "voice": "person.wave.2", "bassBoost": "speaker.wave.3", "trebleBoost": "waveform",
            "lofi": "radio", "telephone": "phone"
        ]
        let eqPrompts: [String: String] = [
            "flat": "an equalizer with all sliders level",
            "voice": "an equalizer emphasising the middle with a mouth",
            "bassBoost": "an equalizer with raised low sliders and a subwoofer",
            "trebleBoost": "an equalizer with raised high sliders",
            "lofi": "a vintage radio with a muffled waveform",
            "telephone": "an old telephone handset with a narrow waveform"
        ]
        var list: [IconSlot] = []
        for eq in EQPreset.allCases {
            list.append(s(eq.iconID, eqSymbols[eq.rawValue] ?? "slider.vertical.3", .audio, "イコライザー：" + eq.label, eqPrompts[eq.rawValue] ?? eq.label))
        }
        let voiceSymbols: [String: String] = [
            "none": "person.wave.2", "chipmunk": "hare", "deep": "tortoise", "robot": "cpu", "alien": "antenna.radiowaves.left.and.right",
            "radio": "radio", "echo": "dot.radiowaves.right"
        ]
        let voicePrompts: [String: String] = [
            "none": "a natural voice waveform",
            "chipmunk": "a tiny squeaky voice with a high-pitched waveform",
            "deep": "a heavy low voice with a deep waveform",
            "robot": "a robot head with a square waveform",
            "alien": "an alien antenna with a wobbly waveform",
            "radio": "a vintage radio speaker",
            "echo": "a voice with repeating fading echoes"
        ]
        for voice in VoicePreset.allCases {
            list.append(s(voice.iconID, voiceSymbols[voice.rawValue] ?? "waveform", .audio, "声：" + voice.label, voicePrompts[voice.rawValue] ?? voice.label))
        }
        return list
    }

    private static func speed() -> [IconSlot] {
        let presetPrompts: [String: String] = [
            "montage": "a speed curve with two fast peaks around a slow middle",
            "hero": "a speed curve dipping into a dramatic slow-motion moment",
            "bullet": "a bullet with a slow-motion trail",
            "jumpCut": "a speed curve jumping fast in the middle",
            "flashIn": "a curve starting fast then settling",
            "flashOut": "a curve settling then rushing out"
        ]
        var list: [IconSlot] = []
        for preset in SpeedMap.presets {
            list.append(s("speed." + preset.id, "chart.xyaxis.line", .speed, "速度カーブ：" + preset.name,
                          presetPrompts[preset.id] ?? preset.name))
        }
        let modeSymbols: [String: String] = ["sampling": "square.on.square", "blending": "square.2.layers.3d", "opticalFlow": "wind"]
        let modePrompts: [String: String] = [
            "sampling": "two identical frames repeated side by side",
            "blending": "two translucent frames blended into one",
            "opticalFlow": "motion vectors flowing between two frames"
        ]
        for mode in FrameInterpolation.allCases {
            list.append(s(mode.iconID, modeSymbols[mode.rawValue] ?? "film", .speed, "コマの補間：" + mode.label,
                          modePrompts[mode.rawValue] ?? mode.label))
        }
        list.append(s("speed.motionBlur", "camera.aperture", .speed, "モーションブラー", "a moving ball with a long motion-blur streak"))
        list.append(s("speed.curveOff", "xmark.circle", .speed, "カーブを解除", "a speed curve with a small X"))
        return list
    }

    private static func export() -> [IconSlot] {
        let prompts: [String: String] = [
            "youtube1080": "a wide 16:9 screen with a play triangle and an upload arrow (generic, no brand logo)",
            "youtube4k": "a wide 16:9 screen with a dense pixel grid suggesting 4K (no text, no brand logo)",
            "tiktok": "a tall 9:16 phone screen with a music note (generic, no brand logo)",
            "reels": "a tall 9:16 frame with a film reel (generic, no brand logo)",
            "feed": "a 4:5 portrait photo card",
            "square": "a 1:1 square photo card",
            "gif": "a small looping frame with a circular arrow"
        ]
        let symbols: [String: String] = [
            "youtube1080": "play.rectangle", "youtube4k": "4k.tv", "tiktok": "music.note.tv", "reels": "film",
            "feed": "rectangle.portrait", "square": "square", "gif": "repeat.circle"
        ]
        var list: [IconSlot] = []
        for preset in ExportPreset.all {
            list.append(s("export." + preset.id, symbols[preset.id] ?? "square.and.arrow.up", .export, "書き出し：" + preset.name,
                          prompts[preset.id] ?? preset.name))
        }
        list.append(s("export.start", "square.and.arrow.up.on.square", .export, "書き出す", "a frame launching upward from a stack"))
        list.append(s("export.photos", "photo.badge.plus", .export, "写真ライブラリに保存", "a photo with a plus badge"))
        list.append(s("export.share", "square.and.arrow.up", .export, "ファイルに保存・共有", "a box with an up arrow"))
        list.append(s("export.lut", "square.and.arrow.down", .export, "LUT を読み込む", "a colour cube with a down arrow"))
        list.append(s("export.model", "arkit", .export, "3D モデルを読み込む", "a 3D cube with a down arrow"))
        return list
    }

    private static func status() -> [IconSlot] {
        let list: [IconSlot] = [
            s("status.done", "checkmark.circle.fill", .status, "完了", "a solid circle with a check mark"),
            s("status.ok", "checkmark.circle", .status, "大丈夫", "an outlined circle with a check mark"),
            s("status.waiting", "hourglass", .status, "待ち・未作成", "an hourglass"),
            s("status.warning", "exclamationmark.triangle", .status, "注意", "a warning triangle with an exclamation mark"),
            s("status.close", "xmark.circle.fill", .status, "閉じる", "a solid circle with an X"),
            s("status.log", "doc.text", .status, "記録", "a document with text lines"),
            s("status.reversePending", "arrow.uturn.backward", .status, "逆再生の準備中", "a U-turn arrow with a small clock")
        ]
        return list
    }
}

// MARK: 種類ごとのアイコンの id

extension EffectKind { var iconID: String { return "effect." + rawValue } }
extension TransitionKind { var iconID: String { return "transition." + rawValue } }
extension AnimationKind { var iconID: String { return "anim." + rawValue } }
extension TextAnimation { var iconID: String { return "textAnim." + rawValue } }
extension ShapeKind { var iconID: String { return "shape." + rawValue } }
extension MaskShape { var iconID: String { return "mask." + rawValue } }
extension FitMode { var iconID: String { return "fit." + rawValue } }
extension AspectPreset { var iconID: String { return "canvas." + rawValue } }
extension LayerBlend { var iconID: String { return "blend." + rawValue } }
extension Object3DKind { var iconID: String { return "object3D." + rawValue } }
extension Lighting3D { var iconID: String { return "light3D." + rawValue } }
extension Motion3D { var iconID: String { return "motion3D." + rawValue } }
extension EQPreset { var iconID: String { return "eq." + rawValue } }
extension VoicePreset { var iconID: String { return "voice." + rawValue } }
extension FrameInterpolation { var iconID: String { return "interp." + rawValue } }
extension RootTool { var iconID: String { return "tool." + rawValue } }
extension MediaKind {
    var iconID: String {
        switch self {
        case .video: return "media.video"
        case .audio: return "media.audio"
        case .image: return "media.image"
        case .gif: return "media.gif"
        case .model3D: return "media.model3D"
        }
    }
}
