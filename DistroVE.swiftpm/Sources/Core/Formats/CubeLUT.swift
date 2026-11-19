import Foundation

/// 3D LUT（.cube）の読み込みと、色の変換表の生成（Q41: LUT 読み込み・カーブ・プリセットフィルター）。
/// data は赤が一番速く変わる順の RGBA（Core Image の CIColorCube と同じ並び）。
struct CubeLUT: Sendable {
    var title: String
    var size: Int
    var data: [Float]

    enum ParseError: Error, LocalizedError {
        case missingSize
        case wrongCount(expected: Int, found: Int)
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .missingSize: return "LUT_3D_SIZE または LUT_1D_SIZE がありません。"
            case .wrongCount(let expected, let found): return "色の数が合いません（\(expected) 個のはずが \(found) 個）。"
            case .tooLarge: return "LUT が大きすぎます（最大 65）。"
            }
        }
    }

    static func parse(_ text: String) throws -> CubeLUT {
        var header = Header()
        var values: [Float] = []
        values.reserveCapacity(36_000 * 3)
        let lines: [Substring] = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        for rawLine in lines {
            let line: String = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || header.read(line) { continue }
            CubeLUT.appendTriple(line, to: &values)
        }
        if header.size3D > 0 { return try CubeLUT.make3D(values, header: header) }
        if header.size1D > 0 { return try CubeLUT.make1D(values, header: header) }
        throw ParseError.missingSize
    }

    /// ヘッダー行（TITLE・LUT_3D_SIZE・DOMAIN_MIN など）の読み取り結果。
    private struct Header {
        var title: String = "LUT"
        var size3D: Int = 0
        var size1D: Int = 0
        var domainMin: [Float] = [0, 0, 0]
        var domainMax: [Float] = [1, 1, 1]

        /// ヘッダー行なら読み取って true を返す（知らない LUT_ 行は読み飛ばす）。
        mutating func read(_ line: String) -> Bool {
            let upper: String = line.uppercased()
            if upper.hasPrefix("TITLE") {
                let rest: String = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else if upper.hasPrefix("LUT_3D_SIZE") {
                size3D = Header.lastInt(line)
            } else if upper.hasPrefix("LUT_1D_SIZE") {
                size1D = Header.lastInt(line)
            } else if upper.hasPrefix("DOMAIN_MIN") {
                domainMin = CubeLUT.parseTriple(line)
            } else if upper.hasPrefix("DOMAIN_MAX") {
                domainMax = CubeLUT.parseTriple(line)
            } else {
                return upper.hasPrefix("LUT_")
            }
            return true
        }

        private static func lastInt(_ line: String) -> Int {
            let last: Substring = line.split(separator: " ").last ?? ""
            return Int(last) ?? 0
        }

        /// 入力の範囲（DOMAIN_MIN〜DOMAIN_MAX）を 0〜1 に直す。
        func normalized(_ value: Float, channel: Int) -> Float {
            let low: Float = domainMin[channel]
            let range: Float = max(0.0001, domainMax[channel] - low)
            return (value - low) / range
        }
    }

    private static func appendTriple(_ line: String, to values: inout [Float]) {
        let parts: [Substring] = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count < 3 { return }
        guard let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else { return }
        values.append(r)
        values.append(g)
        values.append(b)
    }

    private static func make3D(_ values: [Float], header: Header) throws -> CubeLUT {
        let size: Int = header.size3D
        if size > 65 { throw ParseError.tooLarge }
        let expected: Int = size * size * size
        let found: Int = values.count / 3
        if found != expected { throw ParseError.wrongCount(expected: expected, found: found) }
        var data: [Float] = []
        data.reserveCapacity(expected * 4)
        for i in 0..<expected {
            let base: Int = i * 3
            data.append(header.normalized(values[base], channel: 0))
            data.append(header.normalized(values[base + 1], channel: 1))
            data.append(header.normalized(values[base + 2], channel: 2))
            data.append(1)
        }
        return CubeLUT(title: header.title, size: size, data: data)
    }

    /// 1D LUT は 3D の変換表に直して使う。
    private static func make1D(_ values: [Float], header: Header) throws -> CubeLUT {
        let size: Int = header.size1D
        let found: Int = values.count / 3
        if found != size { throw ParseError.wrongCount(expected: size, found: found) }
        var red: [Float] = []
        var green: [Float] = []
        var blue: [Float] = []
        for i in 0..<size {
            let base: Int = i * 3
            red.append(header.normalized(values[base], channel: 0))
            green.append(header.normalized(values[base + 1], channel: 1))
            blue.append(header.normalized(values[base + 2], channel: 2))
        }
        return CubeLUT.generate(size: 33, title: header.title) { r, g, b in
            return (CubeLUT.sample1D(red, r), CubeLUT.sample1D(green, g), CubeLUT.sample1D(blue, b))
        }
    }

    private static func parseTriple(_ line: String) -> [Float] {
        let parts: [Substring] = line.split(separator: " ")
        var result: [Float] = []
        for part in parts.dropFirst() {
            if let v = Float(part) { result.append(v) }
        }
        while result.count < 3 { result.append(result.isEmpty ? 0 : result[result.count - 1]) }
        return result
    }

    static func sample1D(_ table: [Float], _ x: Float) -> Float {
        if table.isEmpty { return x }
        let position: Float = max(0, min(1, x)) * Float(table.count - 1)
        let index: Int = Int(position)
        if index >= table.count - 1 { return table[table.count - 1] }
        let f: Float = position - Float(index)
        return table[index] + (table[index + 1] - table[index]) * f
    }

    /// 関数から変換表を作る。
    static func generate(size: Int, title: String, _ transform: (Float, Float, Float) -> (Float, Float, Float)) -> CubeLUT {
        let n: Int = max(2, size)
        var data: [Float] = []
        data.reserveCapacity(n * n * n * 4)
        let denominator: Float = Float(n - 1)
        for bi in 0..<n {
            let b: Float = Float(bi) / denominator
            for gi in 0..<n {
                let g: Float = Float(gi) / denominator
                for ri in 0..<n {
                    let r: Float = Float(ri) / denominator
                    let out: (Float, Float, Float) = transform(r, g, b)
                    data.append(max(0, min(1, out.0)))
                    data.append(max(0, min(1, out.1)))
                    data.append(max(0, min(1, out.2)))
                    data.append(1)
                }
            }
        }
        return CubeLUT(title: title, size: n, data: data)
    }

    static func identity(size: Int) -> CubeLUT {
        return generate(size: size, title: "Identity") { r, g, b in (r, g, b) }
    }

    /// 3 次元の線形補間で色を引く。
    func sample(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let n: Int = size
        let maxIndex: Float = Float(n - 1)
        let x: Float = max(0, min(1, r)) * maxIndex
        let y: Float = max(0, min(1, g)) * maxIndex
        let z: Float = max(0, min(1, b)) * maxIndex
        let x0: Int = min(Int(x), n - 1)
        let y0: Int = min(Int(y), n - 1)
        let z0: Int = min(Int(z), n - 1)
        let x1: Int = min(x0 + 1, n - 1)
        let y1: Int = min(y0 + 1, n - 1)
        let z1: Int = min(z0 + 1, n - 1)
        let fx: Float = x - Float(x0)
        let fy: Float = y - Float(y0)
        let fz: Float = z - Float(z0)
        var result: [Float] = [0, 0, 0]
        for channel in 0..<3 {
            let c000: Float = value(x0, y0, z0, channel)
            let c100: Float = value(x1, y0, z0, channel)
            let c010: Float = value(x0, y1, z0, channel)
            let c110: Float = value(x1, y1, z0, channel)
            let c001: Float = value(x0, y0, z1, channel)
            let c101: Float = value(x1, y0, z1, channel)
            let c011: Float = value(x0, y1, z1, channel)
            let c111: Float = value(x1, y1, z1, channel)
            let c00: Float = c000 + (c100 - c000) * fx
            let c10: Float = c010 + (c110 - c010) * fx
            let c01: Float = c001 + (c101 - c001) * fx
            let c11: Float = c011 + (c111 - c011) * fx
            let c0: Float = c00 + (c10 - c00) * fy
            let c1: Float = c01 + (c11 - c01) * fy
            result[channel] = c0 + (c1 - c0) * fz
        }
        return (result[0], result[1], result[2])
    }

    private func value(_ x: Int, _ y: Int, _ z: Int, _ channel: Int) -> Float {
        let index: Int = ((z * size + y) * size + x) * 4 + channel
        return data[index]
    }

    /// 強さ（0〜1）で元の色と混ぜた表を作る。
    func blended(intensity: Double) -> CubeLUT {
        let k: Float = Float(Num.clamp(intensity, 0, 1))
        if k >= 0.999 { return self }
        let identityLUT: CubeLUT = CubeLUT.identity(size: size)
        var mixed: [Float] = data
        for i in 0..<mixed.count {
            mixed[i] = identityLUT.data[i] + (data[i] - identityLUT.data[i]) * k
        }
        return CubeLUT(title: title, size: size, data: mixed)
    }

    /// LUT の後にトーンカーブをかけた表を作る（2 つを 1 回の処理で済ませる）。
    static func combined(lut: CubeLUT?, curves: CurveSet?, size: Int = 33) -> CubeLUT {
        let master: [Float] = ToneCurve.table(curves?.master ?? CurveSet.identity)
        let red: [Float] = ToneCurve.table(curves?.red ?? CurveSet.identity)
        let green: [Float] = ToneCurve.table(curves?.green ?? CurveSet.identity)
        let blue: [Float] = ToneCurve.table(curves?.blue ?? CurveSet.identity)
        return generate(size: size, title: "Combined") { r, g, b in
            var c: (Float, Float, Float) = (r, g, b)
            if let lut = lut { c = lut.sample(r, g, b) }
            let mr: Float = sample1D(master, c.0)
            let mg: Float = sample1D(master, c.1)
            let mb: Float = sample1D(master, c.2)
            return (sample1D(red, mr), sample1D(green, mg), sample1D(blue, mb))
        }
    }

    /// .cube 形式の文字列にする（書き出し・共有用）。
    func cubeText() -> String {
        var out: String = "TITLE \"\(title)\"\nLUT_3D_SIZE \(size)\n"
        let count: Int = size * size * size
        for i in 0..<count {
            out += String(format: "%.6f %.6f %.6f\n", data[i * 4], data[i * 4 + 1], data[i * 4 + 2])
        }
        return out
    }
}

/// トーンカーブ（単調な 3 次補間：Fritsch–Carlson）。
enum ToneCurve {
    static func table(_ points: [Vec2], count: Int = 256) -> [Float] {
        var pts: [Vec2] = points.sorted { $0.x < $1.x }
        if pts.isEmpty { pts = CurveSet.identity }
        if pts.count == 1 { pts.append(Vec2(1, 1)) }
        let n: Int = pts.count
        var slopes: [Double] = Array(repeating: 0, count: n)
        var deltas: [Double] = Array(repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            let dx: Double = max(0.000001, pts[i + 1].x - pts[i].x)
            deltas[i] = (pts[i + 1].y - pts[i].y) / dx
        }
        slopes[0] = deltas[0]
        slopes[n - 1] = deltas[n - 2]
        if n > 2 {
            for i in 1..<(n - 1) {
                if deltas[i - 1] * deltas[i] <= 0 {
                    slopes[i] = 0
                } else {
                    slopes[i] = (deltas[i - 1] + deltas[i]) / 2
                }
            }
        }
        for i in 0..<(n - 1) {
            if abs(deltas[i]) < 0.000001 {
                slopes[i] = 0
                slopes[i + 1] = 0
                continue
            }
            let a: Double = slopes[i] / deltas[i]
            let b: Double = slopes[i + 1] / deltas[i]
            let s: Double = a * a + b * b
            if s > 9 {
                let tau: Double = 3 / s.squareRoot()
                slopes[i] = tau * a * deltas[i]
                slopes[i + 1] = tau * b * deltas[i]
            }
        }
        var result: [Float] = []
        result.reserveCapacity(count)
        var segment: Int = 0
        for k in 0..<count {
            let x: Double = Double(k) / Double(count - 1)
            if x <= pts[0].x {
                result.append(Float(Num.clamp(pts[0].y, 0, 1)))
                continue
            }
            if x >= pts[n - 1].x {
                result.append(Float(Num.clamp(pts[n - 1].y, 0, 1)))
                continue
            }
            while segment < n - 2 && x > pts[segment + 1].x { segment += 1 }
            let x0: Double = pts[segment].x
            let x1: Double = pts[segment + 1].x
            let h: Double = max(0.000001, x1 - x0)
            let t: Double = (x - x0) / h
            let t2: Double = t * t
            let t3: Double = t2 * t
            let h00: Double = 2 * t3 - 3 * t2 + 1
            let h10: Double = t3 - 2 * t2 + t
            let h01: Double = -2 * t3 + 3 * t2
            let h11: Double = t3 - t2
            let y: Double = h00 * pts[segment].y + h10 * h * slopes[segment] + h01 * pts[segment + 1].y + h11 * h * slopes[segment + 1]
            result.append(Float(Num.clamp(y, 0, 1)))
        }
        return result
    }
}
