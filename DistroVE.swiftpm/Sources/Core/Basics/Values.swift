import Foundation

/// 色（0〜1 の RGBA、sRGB）。
struct RGBA: Hashable, Codable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let black = RGBA(0, 0, 0, 1)
    static let white = RGBA(1, 1, 1, 1)
    static let clear = RGBA(0, 0, 0, 0)
    static let green = RGBA(0, 1, 0, 1)
    static let yellow = RGBA(1, 0.86, 0.1, 1)

    /// "#RRGGBB" または "#RRGGBBAA"。
    init?(hex: String) {
        var text: String = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let parsed = UInt64(text, radix: 16) else { return nil }
        let value: UInt64 = text.count == 6 ? (parsed << 8) | 0xFF : parsed
        r = RGBA.channel(value, shift: 24)
        g = RGBA.channel(value, shift: 16)
        b = RGBA.channel(value, shift: 8)
        a = RGBA.channel(value, shift: 0)
    }

    private static func channel(_ value: UInt64, shift: UInt64) -> Double {
        let byte: UInt64 = (value >> shift) & 0xFF
        return Double(byte) / 255.0
    }

    var hex: String {
        let ri: Int = Int((r * 255).rounded())
        let gi: Int = Int((g * 255).rounded())
        let bi: Int = Int((b * 255).rounded())
        if a >= 0.999 {
            return String(format: "#%02X%02X%02X", ri, gi, bi)
        }
        let ai: Int = Int((a * 255).rounded())
        return String(format: "#%02X%02X%02X%02X", ri, gi, bi, ai)
    }

    func withAlpha(_ alpha: Double) -> RGBA {
        return RGBA(r, g, b, alpha)
    }

    /// 色相（0〜1）。
    var hue: Double {
        let maxValue: Double = max(r, max(g, b))
        let minValue: Double = min(r, min(g, b))
        let delta: Double = maxValue - minValue
        if delta < 0.00001 { return 0 }
        var h: Double
        if maxValue == r {
            h = (g - b) / delta
        } else if maxValue == g {
            h = 2 + (b - r) / delta
        } else {
            h = 4 + (r - g) / delta
        }
        h /= 6
        if h < 0 { h += 1 }
        return h
    }
}

/// 2 次元ベクトル（正規化座標などに使う）。
struct Vec2: Hashable, Codable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    static let zero = Vec2(0, 0)
}

/// 数値の小さなユーティリティ。
enum Num {
    static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        if value < lower { return lower }
        if value > upper { return upper }
        return value
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        return a + (b - a) * t
    }

    static func dB(fromLinear value: Double) -> Double {
        if value <= 0.0000001 { return -140 }
        return 20 * log10(value)
    }

    static func linear(fromDB value: Double) -> Double {
        return pow(10, value / 20)
    }

    /// 決まった種から 0〜1 の疑似乱数を作る（グリッチや手ぶれ演出をフレームごとに再現できるようにする）。
    static func hash01(_ seed: Int) -> Double {
        var x: UInt64 = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15
        x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
        x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
        x = x ^ (x >> 31)
        return Double(x % 1_000_000) / 1_000_000.0
    }
}
