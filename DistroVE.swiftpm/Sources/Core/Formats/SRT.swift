import Foundation

/// SRT 字幕の読み込みと書き出し（Q56）。WebVTT の「.」区切りや番号の抜けにも寛容にする。
enum SRT {
    static func parse(_ text: String) -> [SubtitleCue] {
        var normalized: String = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        if normalized.hasPrefix("\u{FEFF}") { normalized.removeFirst() }
        let lines: [String] = normalized.components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        var index: Int = 0
        while index < lines.count {
            let line: String = lines[index].trimmingCharacters(in: .whitespaces)
            if let times = parseTimingLine(line) {
                var textLines: [String] = []
                index += 1
                while index < lines.count {
                    let content: String = lines[index]
                    if content.trimmingCharacters(in: .whitespaces).isEmpty { break }
                    if parseTimingLine(content.trimmingCharacters(in: .whitespaces)) != nil { break }
                    textLines.append(content)
                    index += 1
                }
                // 次の字幕の番号行が紛れ込んだ場合は外す
                if let last = textLines.last, Int(last.trimmingCharacters(in: .whitespaces)) != nil, textLines.count > 1 {
                    textLines.removeLast()
                }
                let body: String = stripTags(textLines.joined(separator: "\n"))
                if times.1 > times.0 {
                    cues.append(SubtitleCue(start: times.0, end: times.1, text: body))
                }
            } else {
                index += 1
            }
        }
        cues.sort { $0.start < $1.start }
        return cues
    }

    static func parseTimingLine(_ line: String) -> (Time, Time)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left: String = String(line[line.startIndex..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
        var right: String = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        if let space = right.firstIndex(of: " ") {
            right = String(right[right.startIndex..<space])
        }
        guard let start = parseTimestamp(left), let end = parseTimestamp(right) else { return nil }
        return (start, end)
    }

    /// "00:01:02,345" / "01:02.345" / "1:02:03.4" を読む。
    static func parseTimestamp(_ text: String) -> Time? {
        let cleaned: String = text.replacingOccurrences(of: ",", with: ".")
        let parts: [String] = cleaned.components(separatedBy: ":")
        if parts.count < 2 || parts.count > 3 { return nil }
        var hours: Double = 0
        var minutes: Double = 0
        var seconds: Double = 0
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            hours = h
            minutes = m
            seconds = s
        } else {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            minutes = m
            seconds = s
        }
        let total: Double = hours * 3600 + minutes * 60 + seconds
        return Time(seconds: total)
    }

    static func stripTags(_ text: String) -> String {
        var result: String = ""
        var insideTag: Bool = false
        for ch in text {
            if ch == "<" {
                insideTag = true
            } else if ch == ">" && insideTag {
                insideTag = false
            } else if !insideTag {
                result.append(ch)
            }
        }
        return result
    }

    static func timestamp(_ time: Time, separator: String = ",") -> String {
        let totalMillis: Int64 = max(0, (time.ticks * 1000 + Time.timescale / 2) / Time.timescale)
        let millis: Int64 = totalMillis % 1000
        let totalSeconds: Int64 = totalMillis / 1000
        let s: Int64 = totalSeconds % 60
        let m: Int64 = (totalSeconds / 60) % 60
        let h: Int64 = totalSeconds / 3600
        return String(format: "%02lld:%02lld:%02lld", h, m, s) + separator + String(format: "%03lld", millis)
    }

    static func export(_ cues: [SubtitleCue], useTranslation: Bool = false, offset: Time = .zero) -> String {
        var out: String = ""
        var number: Int = 1
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            var text: String = cue.text
            if useTranslation, let translated = cue.translation, !translated.isEmpty {
                text = translated
            }
            out += "\(number)\n"
            out += timestamp(cue.start + offset) + " --> " + timestamp(cue.end + offset) + "\n"
            out += text + "\n\n"
            number += 1
        }
        return out
    }

    static func exportVTT(_ cues: [SubtitleCue], offset: Time = .zero) -> String {
        var out: String = "WEBVTT\n\n"
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            out += timestamp(cue.start + offset, separator: ".") + " --> " + timestamp(cue.end + offset, separator: ".") + "\n"
            out += cue.text + "\n\n"
        }
        return out
    }
}
