import Foundation

/// 8 ビット RGBA の絵（前乗算なし。左上から 1 行ずつ）。
struct IconBitmap: Equatable, Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: Array(repeating: 0, count: width * height * 4))
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 {
        return pixels[(y * width + x) * 4 + 3]
    }

    /// x0..<x1, y0..<y1 を切り出す。
    func cropped(x0: Int, y0: Int, x1: Int, y1: Int) -> IconBitmap {
        let w: Int = max(1, x1 - x0)
        let h: Int = max(1, y1 - y0)
        var out = IconBitmap(width: w, height: h)
        for y in 0..<h {
            let source: Int = ((y0 + y) * width + x0) * 4
            let target: Int = y * w * 4
            for i in 0..<(w * 4) {
                out.pixels[target + i] = pixels[source + i]
            }
        }
        return out
    }
}

/// 取り込んだアイコンの画像を、アプリで使える形にそろえる（ChatGPT などで作った画像の取り込み）。
/// - 背景が透明でなければ、縁の色を背景とみなして透明にする（白地・黒地のどちらでも）
/// - 色付きか単色かを見分ける（単色ならアプリの文字の色で塗る。色付きならそのまま出す）
/// - 余白を切り詰め、真ん中に同じ大きさでおさめる（アイコンごとの大きさのばらつきをなくす）
/// - 4×4 などに並べた 1 枚の画像（シート）を、すき間を探して 1 つずつに切り分ける
enum IconImageProcessor {
    struct Result: Equatable, Sendable {
        var bitmap: IconBitmap
        var isColor: Bool
    }

    /// 出力の大きさ（画素）と、中身が占める割合。
    static let outputSize: Int = 256
    static let contentFill: Double = 0.84

    /// 1 つのアイコンをそろえる。中身が無ければ nil。
    static func process(_ input: IconBitmap, size: Int = outputSize, fill: Double = contentFill) -> Result? {
        if input.width < 2 || input.height < 2 { return nil }
        let cleaned: (bitmap: IconBitmap, isColor: Bool) = removeBackground(input)
        guard let box = bounds(cleaned.bitmap) else { return nil }
        var fitted: IconBitmap = fit(cleaned.bitmap, box: box, size: size, fill: fill)
        if !cleaned.isColor {
            // 単色のアイコンは白にして、形（不透明度）だけを残す（アプリが色を塗る）
            var i: Int = 0
            while i < fitted.pixels.count {
                fitted.pixels[i] = 255
                fitted.pixels[i + 1] = 255
                fitted.pixels[i + 2] = 255
                i += 4
            }
        }
        return Result(bitmap: fitted, isColor: cleaned.isColor)
    }

    /// 横長のロゴなど：背景を透明にして余白を切り詰め、形（縦横比）はそのままに長い辺を maxSide にそろえる。
    static func processWide(_ input: IconBitmap, maxSide: Int = 1024) -> Result? {
        if input.width < 2 || input.height < 2 { return nil }
        let cleaned: (bitmap: IconBitmap, isColor: Bool) = removeBackground(input)
        guard let box = bounds(cleaned.bitmap) else { return nil }
        let boxWidth: Int = box.x1 - box.x0
        let boxHeight: Int = box.y1 - box.y0
        let longest: Int = max(boxWidth, boxHeight)
        let scale: Double = Double(maxSide) / Double(longest)
        let width: Int = max(1, Int((Double(boxWidth) * scale).rounded()))
        let height: Int = max(1, Int((Double(boxHeight) * scale).rounded()))
        // fit は正方形に置くので、いったん正方形に置いてから中身の行と列だけを切り出す
        let side: Int = max(width, height)
        let square: IconBitmap = fit(cleaned.bitmap, box: box, size: side, fill: 1)
        let left: Int = (side - width) / 2
        let top: Int = (side - height) / 2
        let out: IconBitmap = square.cropped(x0: left, y0: top, x1: left + width, y1: top + height)
        return Result(bitmap: out, isColor: true)
    }

    /// 透明な所がどれだけあるか（2% 以上なら、背景はもう透明とみなす）。
    static func hasTransparency(_ b: IconBitmap) -> Bool {
        var count: Int = 0
        var i: Int = 3
        while i < b.pixels.count {
            if b.pixels[i] < 250 { count += 1 }
            i += 4
        }
        return count * 50 > b.width * b.height
    }

    /// 縁の色（中央値）。
    static func borderColor(_ b: IconBitmap) -> (r: Int, g: Int, b: Int) {
        var reds: [Int] = []
        var greens: [Int] = []
        var blues: [Int] = []
        func take(_ x: Int, _ y: Int) {
            let p: Int = (y * b.width + x) * 4
            reds.append(Int(b.pixels[p]))
            greens.append(Int(b.pixels[p + 1]))
            blues.append(Int(b.pixels[p + 2]))
        }
        for x in 0..<b.width {
            take(x, 0)
            take(x, b.height - 1)
        }
        for y in 1..<max(1, b.height - 1) {
            take(0, y)
            take(b.width - 1, y)
        }
        reds.sort()
        greens.sort()
        blues.sort()
        let middle: Int = reds.count / 2
        return (reds[middle], greens[middle], blues[middle])
    }

    /// 背景を透明にする。戻り値の isColor は色付きのアイコンか。
    static func removeBackground(_ input: IconBitmap) -> (bitmap: IconBitmap, isColor: Bool) {
        if hasTransparency(input) {
            return (input, isColorful(input))
        }
        let background: (r: Int, g: Int, b: Int) = borderColor(input)
        let count: Int = input.width * input.height
        // 背景の色からの離れ具合で、まず不透明度を決める
        var distance: [UInt8] = Array(repeating: 0, count: count)
        for i in 0..<count {
            let p: Int = i * 4
            let dr: Int = abs(Int(input.pixels[p]) - background.r)
            let dg: Int = abs(Int(input.pixels[p + 1]) - background.g)
            let db: Int = abs(Int(input.pixels[p + 2]) - background.b)
            distance[i] = UInt8(min(255, max(dr, max(dg, db))))
        }
        var keyed: IconBitmap = unblend(input, distance: distance, background: background, mask: nil)
        let colorful: Bool = isColorful(keyed)
        if colorful {
            // 色付きのアイコンは、縁からつながった背景だけを消す（中の白い部分などを残す）
            let outside: [Bool] = floodBackground(distance: distance, width: input.width, height: input.height)
            keyed = unblend(input, distance: distance, background: background, mask: outside)
        }
        return (keyed, colorful)
    }

    private static let keyLow: Int = 14
    private static let keyHigh: Int = 64

    /// 背景の色を引いて、前景の色と不透明度に分ける。mask があれば、mask の外（false）は不透明のまま。
    private static func unblend(_ input: IconBitmap, distance: [UInt8], background: (r: Int, g: Int, b: Int), mask: [Bool]?) -> IconBitmap {
        var out = IconBitmap(width: input.width, height: input.height)
        let count: Int = input.width * input.height
        for i in 0..<count {
            let p: Int = i * 4
            var alpha: Double = Num.clamp(Double(Int(distance[i]) - keyLow) / Double(keyHigh - keyLow), 0, 1)
            if let m = mask, !m[i] { alpha = 1 }
            if alpha <= 0 { continue }
            let channels: [Int] = [background.r, background.g, background.b]
            for c in 0..<3 {
                let value: Double = Double(input.pixels[p + c])
                let restored: Double = (value - (1 - alpha) * Double(channels[c])) / alpha
                out.pixels[p + c] = UInt8(Num.clamp(restored.rounded(), 0, 255))
            }
            out.pixels[p + 3] = UInt8((alpha * 255).rounded())
        }
        return out
    }

    /// 縁からつながった「背景に近い色」の所（true が背景）。
    private static func floodBackground(distance: [UInt8], width: Int, height: Int) -> [Bool] {
        var outside: [Bool] = Array(repeating: false, count: width * height)
        var queue: [Int] = []
        queue.reserveCapacity(width * 4)
        func push(_ i: Int) {
            if outside[i] || Int(distance[i]) >= keyHigh { return }
            outside[i] = true
            queue.append(i)
        }
        for x in 0..<width {
            push(x)
            push((height - 1) * width + x)
        }
        for y in 0..<height {
            push(y * width)
            push(y * width + width - 1)
        }
        var head: Int = 0
        while head < queue.count {
            let i: Int = queue[head]
            head += 1
            let x: Int = i % width
            let y: Int = i / width
            if x > 0 { push(i - 1) }
            if x < width - 1 { push(i + 1) }
            if y > 0 { push(i - width) }
            if y < height - 1 { push(i + width) }
        }
        return outside
    }

    /// 色付きか（不透明な所のうち、はっきり色の付いた画素が 15% 以上）。
    static func isColorful(_ b: IconBitmap) -> Bool {
        var opaque: Int = 0
        var colored: Int = 0
        var i: Int = 0
        while i < b.pixels.count {
            if b.pixels[i + 3] > 128 {
                opaque += 1
                let r: Int = Int(b.pixels[i])
                let g: Int = Int(b.pixels[i + 1])
                let bl: Int = Int(b.pixels[i + 2])
                let high: Int = max(r, max(g, bl))
                let low: Int = min(r, min(g, bl))
                if high > 40 && high - low > 60 { colored += 1 }
            }
            i += 4
        }
        return opaque > 0 && colored * 100 > opaque * 15
    }

    /// 不透明な所を囲む範囲（x0..<x1, y0..<y1）。
    static func bounds(_ b: IconBitmap, threshold: UInt8 = 10) -> (x0: Int, y0: Int, x1: Int, y1: Int)? {
        var x0: Int = b.width
        var y0: Int = b.height
        var x1: Int = -1
        var y1: Int = -1
        for y in 0..<b.height {
            for x in 0..<b.width where b.alpha(x, y) > threshold {
                x0 = min(x0, x)
                y0 = min(y0, y)
                x1 = max(x1, x)
                y1 = max(y1, y)
            }
        }
        if x1 < 0 { return nil }
        return (x0, y0, x1 + 1, y1 + 1)
    }

    /// box の中身を、size × size の真ん中に fill の割合でおさめる（縮めるときは面積の平均、広げるときは双一次）。
    static func fit(_ b: IconBitmap, box: (x0: Int, y0: Int, x1: Int, y1: Int), size: Int, fill: Double) -> IconBitmap {
        let boxWidth: Double = Double(box.x1 - box.x0)
        let boxHeight: Double = Double(box.y1 - box.y0)
        let target: Double = Double(size) * fill
        let scale: Double = target / max(boxWidth, boxHeight)
        let outWidth: Double = boxWidth * scale
        let outHeight: Double = boxHeight * scale
        let left: Double = (Double(size) - outWidth) / 2
        let top: Double = (Double(size) - outHeight) / 2
        var out = IconBitmap(width: size, height: size)
        for y in 0..<size {
            let fy0: Double = (Double(y) - top) / scale + Double(box.y0)
            let fy1: Double = (Double(y + 1) - top) / scale + Double(box.y0)
            if fy1 <= Double(box.y0) || fy0 >= Double(box.y1) { continue }
            for x in 0..<size {
                let fx0: Double = (Double(x) - left) / scale + Double(box.x0)
                let fx1: Double = (Double(x + 1) - left) / scale + Double(box.x0)
                if fx1 <= Double(box.x0) || fx0 >= Double(box.x1) { continue }
                let color: [Double] = scale < 1
                    ? average(b, x0: fx0, y0: fy0, x1: fx1, y1: fy1)
                    : bilinear(b, x: (fx0 + fx1) / 2 - 0.5, y: (fy0 + fy1) / 2 - 0.5)
                let p: Int = (y * size + x) * 4
                let alpha: Double = color[3]
                if alpha <= 0.001 { continue }
                out.pixels[p] = UInt8(Num.clamp((color[0] / alpha).rounded(), 0, 255))
                out.pixels[p + 1] = UInt8(Num.clamp((color[1] / alpha).rounded(), 0, 255))
                out.pixels[p + 2] = UInt8(Num.clamp((color[2] / alpha).rounded(), 0, 255))
                out.pixels[p + 3] = UInt8(Num.clamp(alpha.rounded(), 0, 255))
            }
        }
        return out
    }

    /// 範囲の面積の平均。RGB は「色 × 不透明度（0〜255）」の平均、4 つ目は不透明度の平均（fit で割り戻す）。
    private static func average(_ b: IconBitmap, x0: Double, y0: Double, x1: Double, y1: Double) -> [Double] {
        var sum: [Double] = [0, 0, 0, 0]
        var area: Double = 0
        let startY: Int = max(0, Int(y0.rounded(.down)))
        let endY: Int = min(b.height, Int(y1.rounded(.up)))
        let startX: Int = max(0, Int(x0.rounded(.down)))
        let endX: Int = min(b.width, Int(x1.rounded(.up)))
        if startY >= endY || startX >= endX { return sum }
        for y in startY..<endY {
            let coverY: Double = min(y1, Double(y + 1)) - max(y0, Double(y))
            if coverY <= 0 { continue }
            for x in startX..<endX {
                let coverX: Double = min(x1, Double(x + 1)) - max(x0, Double(x))
                if coverX <= 0 { continue }
                let weight: Double = coverX * coverY
                let p: Int = (y * b.width + x) * 4
                let alpha: Double = Double(b.pixels[p + 3])
                sum[0] += Double(b.pixels[p]) * alpha * weight
                sum[1] += Double(b.pixels[p + 1]) * alpha * weight
                sum[2] += Double(b.pixels[p + 2]) * alpha * weight
                sum[3] += alpha * weight
                area += weight
            }
        }
        if area <= 0 { return [0, 0, 0, 0] }
        return [sum[0] / area, sum[1] / area, sum[2] / area, sum[3] / area]
    }

    /// 双一次の補間（average と同じ形で返す）。
    private static func bilinear(_ b: IconBitmap, x: Double, y: Double) -> [Double] {
        let cx: Double = Num.clamp(x, 0, Double(b.width - 1))
        let cy: Double = Num.clamp(y, 0, Double(b.height - 1))
        let x0: Int = Int(cx.rounded(.down))
        let y0: Int = Int(cy.rounded(.down))
        let x1: Int = min(b.width - 1, x0 + 1)
        let y1: Int = min(b.height - 1, y0 + 1)
        let wx: Double = cx - Double(x0)
        let wy: Double = cy - Double(y0)
        var result: [Double] = [0, 0, 0, 0]
        let corners: [(Int, Int, Double)] = [(x0, y0, (1 - wx) * (1 - wy)), (x1, y0, wx * (1 - wy)), (x0, y1, (1 - wx) * wy), (x1, y1, wx * wy)]
        for corner in corners {
            let p: Int = (corner.1 * b.width + corner.0) * 4
            let alpha: Double = Double(b.pixels[p + 3])
            result[0] += Double(b.pixels[p]) * alpha * corner.2
            result[1] += Double(b.pixels[p + 1]) * alpha * corner.2
            result[2] += Double(b.pixels[p + 2]) * alpha * corner.2
            result[3] += alpha * corner.2
        }
        return result
    }

    // MARK: シート

    /// rows × columns に並べた 1 枚の画像を切り分ける（左上から右へ、行ごと）。すき間（何も無い列・行）を探して切る。
    static func slice(_ sheet: IconBitmap, rows: Int, columns: Int) -> [IconBitmap] {
        if rows < 1 || columns < 1 { return [] }
        let cleaned: IconBitmap = removeBackground(sheet).bitmap
        var columnMass: [Int] = Array(repeating: 0, count: cleaned.width)
        var rowMass: [Int] = Array(repeating: 0, count: cleaned.height)
        for y in 0..<cleaned.height {
            for x in 0..<cleaned.width {
                let a: Int = Int(cleaned.alpha(x, y))
                columnMass[x] += a
                rowMass[y] += a
            }
        }
        let xs: [Int] = cuts(mass: columnMass, parts: columns)
        let ys: [Int] = cuts(mass: rowMass, parts: rows)
        var result: [IconBitmap] = []
        for r in 0..<rows {
            for c in 0..<columns {
                result.append(cleaned.cropped(x0: xs[c], y0: ys[r], x1: xs[c + 1], y1: ys[r + 1]))
            }
        }
        return result
    }

    /// parts 個に分ける切れ目（両端を含む）。等分の位置の近くで、いちばん中身の少ない所を選ぶ。
    static func cuts(mass: [Int], parts: Int) -> [Int] {
        let length: Int = mass.count
        var result: [Int] = [0]
        let cell: Double = Double(length) / Double(parts)
        for k in 1..<max(1, parts) {
            let expected: Int = Int((Double(k) * cell).rounded())
            let reach: Int = max(1, Int(cell * 0.3))
            var best: Int = expected
            var bestMass: Int = Int.max
            var bestDistance: Int = Int.max
            let lower: Int = max(result[result.count - 1] + 1, expected - reach)
            let upper: Int = min(length - 1, expected + reach)
            if lower <= upper {
                for x in lower...upper {
                    let distance: Int = abs(x - expected)
                    if mass[x] < bestMass || (mass[x] == bestMass && distance < bestDistance) {
                        best = x
                        bestMass = mass[x]
                        bestDistance = distance
                    }
                }
            }
            result.append(best)
        }
        result.append(length)
        return result
    }
}
