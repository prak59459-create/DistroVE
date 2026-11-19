import Foundation

/// 字幕 1 行分（Q56〜Q58）。
struct SubtitleCue: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var start: Time
    var end: Time
    var text: String
    /// 話者番号（色分け用。0 が既定）
    var speaker: Int
    /// 自動翻訳の結果
    var translation: String?

    init(start: Time, end: Time, text: String, speaker: Int = 0) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.translation = nil
    }

    var duration: Time { return end - start }
    var range: TimeRange { return TimeRange(start: start, end: end) }
}

/// 字幕の見た目（Q57）。
struct SubtitleStyle: Hashable, Codable, Sendable {
    var fontName: String
    /// キャンバス高さに対する割合
    var size: Double
    var color: RGBA
    var strokeColor: RGBA
    var strokeWidth: Double
    /// 背景の帯（a が 0 なら無し）
    var bandColor: RGBA
    /// 下端からの位置（キャンバス高さに対する割合）
    var bottomMargin: Double
    /// 話者ごとの文字色
    var speakerColors: [RGBA]
    var animation: TextAnimation
    /// 翻訳を原文の下に出す
    var showTranslation: Bool
    var translationLanguage: String?

    init() {
        fontName = ""
        size = 0.048
        color = .white
        strokeColor = .black
        strokeWidth = 0.12
        bandColor = .clear
        bottomMargin = 0.08
        speakerColors = [RGBA.white, RGBA(1, 0.86, 0.2), RGBA(0.45, 0.85, 1), RGBA(1, 0.55, 0.7), RGBA(0.6, 1, 0.6)]
        animation = .none
        showTranslation = false
        translationLanguage = nil
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, size, color, strokeColor, strokeWidth, bandColor, bottomMargin
        case speakerColors, animation, showTranslation, translationLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = SubtitleStyle()
        fontName = c.value(.fontName, base.fontName)
        size = c.value(.size, base.size)
        color = c.value(.color, base.color)
        strokeColor = c.value(.strokeColor, base.strokeColor)
        strokeWidth = c.value(.strokeWidth, base.strokeWidth)
        bandColor = c.value(.bandColor, base.bandColor)
        bottomMargin = c.value(.bottomMargin, base.bottomMargin)
        speakerColors = c.value(.speakerColors, base.speakerColors)
        animation = c.value(.animation, base.animation)
        showTranslation = c.value(.showTranslation, base.showTranslation)
        translationLanguage = c.optional(.translationLanguage, String.self)
    }

    func color(forSpeaker speaker: Int) -> RGBA {
        if speaker <= 0 || speakerColors.isEmpty { return color }
        return speakerColors[speaker % speakerColors.count]
    }

    /// 字幕をテキストとして描くときの設定。
    func textContent(for cue: SubtitleCue) -> TextContent {
        var t = TextContent(string: cue.text)
        if showTranslation, let translated = cue.translation, !translated.isEmpty {
            t.string = cue.text + "\n" + translated
        }
        t.fontName = fontName
        t.size = size
        t.color = color(forSpeaker: cue.speaker)
        t.strokeColor = strokeColor
        t.strokeWidth = strokeWidth
        t.shadowBlur = 0
        t.backgroundColor = bandColor
        t.backgroundPadding = 0.35
        t.animation = animation
        t.animationDuration = 0.25
        t.maxWidth = 0.92
        return t
    }
}
