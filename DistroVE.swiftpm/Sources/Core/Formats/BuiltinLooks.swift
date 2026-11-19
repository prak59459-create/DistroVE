import Foundation

/// 内蔵のフィルター（色味）。すべて計算で LUT を作るので、画像ファイルを同梱しない。
enum BuiltinLooks {
    struct Look: Identifiable, Sendable {
        let id: String
        let label: String
    }

    static let all: [Look] = [
        Look(id: "vivid", label: "ビビッド"),
        Look(id: "film", label: "フィルム"),
        Look(id: "tealOrange", label: "ティール＆オレンジ"),
        Look(id: "vintage", label: "ビンテージ"),
        Look(id: "pastel", label: "パステル"),
        Look(id: "golden", label: "ゴールデン"),
        Look(id: "cool", label: "クール"),
        Look(id: "warm", label: "ウォーム"),
        Look(id: "cyberpunk", label: "サイバーパンク"),
        Look(id: "phonkDark", label: "phonk ダーク"),
        Look(id: "bleach", label: "銀残し"),
        Look(id: "matrix", label: "マトリックス"),
        Look(id: "mono", label: "モノクロ"),
        Look(id: "noir", label: "ノワール")
    ]

    static func label(for id: String) -> String {
        return all.first { $0.id == id }?.label ?? id
    }

    typealias RGB = (Float, Float, Float)

    static func lut(named name: String, size: Int = 25) -> CubeLUT? {
        guard let transform = transform(named: name) else { return nil }
        return CubeLUT.generate(size: size, title: name, transform)
    }

    static func transform(named name: String) -> ((Float, Float, Float) -> RGB)? {
        switch name {
        case "vivid":
            return { r, g, b in contrast(saturate((r, g, b), 1.35), 0.12) }
        case "film":
            return { r, g, b in lift(warm(contrast((r, g, b), 0.1), 0.04), 0.04) }
        case "tealOrange":
            return { r, g, b in saturate(splitTone((r, g, b), shadow: (0.0, 0.45, 0.55), highlight: (1.0, 0.6, 0.3), amount: 0.35), 1.1) }
        case "vintage":
            return { r, g, b in lift(warm(saturate((r, g, b), 0.75), 0.08), 0.09) }
        case "pastel":
            return { r, g, b in lift(contrast(saturate((r, g, b), 0.8), -0.1), 0.1) }
        case "golden":
            return { r, g, b in splitTone(warm((r, g, b), 0.1), shadow: (0.3, 0.2, 0.1), highlight: (1.0, 0.8, 0.45), amount: 0.25) }
        case "cool":
            return { r, g, b in warm((r, g, b), -0.1) }
        case "warm":
            return { r, g, b in warm((r, g, b), 0.12) }
        case "cyberpunk":
            return { r, g, b in saturate(splitTone((r, g, b), shadow: (0.55, 0.0, 0.75), highlight: (0.0, 0.95, 1.0), amount: 0.45), 1.3) }
        case "phonkDark":
            return { r, g, b in crush(contrast(tint(saturate((r, g, b), 0.55), (1.0, 0.35, 0.35), 0.18), 0.25), 0.06) }
        case "bleach":
            return { r, g, b in contrast(saturate((r, g, b), 0.45), 0.2) }
        case "matrix":
            return { r, g, b in tint(contrast((r, g, b), 0.1), (0.4, 1.0, 0.5), 0.3) }
        case "mono":
            return { r, g, b in
                let l: Float = luminance((r, g, b))
                return contrast((l, l, l), 0.05)
            }
        case "noir":
            return { r, g, b in
                let l: Float = luminance((r, g, b))
                return crush(contrast((l, l, l), 0.35), 0.04)
            }
        default:
            return nil
        }
    }

    // MARK: 色の部品

    static func luminance(_ c: RGB) -> Float {
        return 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    static func saturate(_ c: RGB, _ amount: Float) -> RGB {
        let l: Float = luminance(c)
        return (l + (c.0 - l) * amount, l + (c.1 - l) * amount, l + (c.2 - l) * amount)
    }

    /// 0.5 を中心にした S 字のコントラスト（負の値で弱める）。
    static func contrast(_ c: RGB, _ amount: Float) -> RGB {
        return (sCurve(c.0, amount), sCurve(c.1, amount), sCurve(c.2, amount))
    }

    static func sCurve(_ x: Float, _ amount: Float) -> Float {
        let v: Float = max(0, min(1, x))
        let s: Float = v * v * (3 - 2 * v)
        return v + (s - v) * amount * 2
    }

    /// 黒を持ち上げる（フェード）。
    static func lift(_ c: RGB, _ amount: Float) -> RGB {
        return (amount + c.0 * (1 - amount), amount + c.1 * (1 - amount), amount + c.2 * (1 - amount))
    }

    /// 暗部をつぶす。
    static func crush(_ c: RGB, _ amount: Float) -> RGB {
        let k: Float = 1 / max(0.01, 1 - amount)
        return (max(0, (c.0 - amount) * k), max(0, (c.1 - amount) * k), max(0, (c.2 - amount) * k))
    }

    static func warm(_ c: RGB, _ amount: Float) -> RGB {
        return (c.0 + amount, c.1 + amount * 0.35, c.2 - amount)
    }

    static func tint(_ c: RGB, _ color: RGB, _ amount: Float) -> RGB {
        let l: Float = luminance(c)
        let target: RGB = (l * color.0, l * color.1, l * color.2)
        return (c.0 + (target.0 - c.0) * amount, c.1 + (target.1 - c.1) * amount, c.2 + (target.2 - c.2) * amount)
    }

    /// 暗部と明部に別の色を乗せる。
    static func splitTone(_ c: RGB, shadow: RGB, highlight: RGB, amount: Float) -> RGB {
        let l: Float = luminance(c)
        let hw: Float = max(0, min(1, (l - 0.35) / 0.5))
        let sw: Float = 1 - hw
        let tr: Float = shadow.0 * sw + highlight.0 * hw
        let tg: Float = shadow.1 * sw + highlight.1 * hw
        let tb: Float = shadow.2 * sw + highlight.2 * hw
        let k: Float = amount * (1 - abs(l - 0.5))
        return (c.0 + (tr * l * 1.6 - c.0) * k, c.1 + (tg * l * 1.6 - c.1) * k, c.2 + (tb * l * 1.6 - c.2) * k)
    }
}
