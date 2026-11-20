import Foundation

/// 動きの場（A の各点が B でどこへ動いたか。画素単位）。
struct FlowField: Sendable {
    let width: Int
    let height: Int
    /// (dx, dy) を交互に並べたもの
    var vectors: [Float]

    init(width: Int, height: Int, vectors: [Float]) {
        self.width = width
        self.height = height
        self.vectors = vectors
    }

    init(width: Int, height: Int) {
        self.init(width: width, height: height, vectors: Array(repeating: 0, count: width * height * 2))
    }

    func at(_ x: Int, _ y: Int) -> (dx: Float, dy: Float) {
        let cx: Int = max(0, min(width - 1, x))
        let cy: Int = max(0, min(height - 1, y))
        let i: Int = (cy * width + cx) * 2
        return (vectors[i], vectors[i + 1])
    }

    /// 真ん中あたり（端を除く）の動きの平均。
    var interiorMean: (dx: Float, dy: Float) {
        var sx: Float = 0
        var sy: Float = 0
        var n: Float = 0
        let mx: Int = width / 4
        let my: Int = height / 4
        for y in my..<max(my + 1, height - my) {
            for x in mx..<max(mx + 1, width - mx) {
                let v: (dx: Float, dy: Float) = at(x, y)
                sx += v.dx
                sy += v.dy
                n += 1
            }
        }
        return n > 0 ? (sx / n, sy / n) : (0, 0)
    }
}

/// 明るさだけの絵（0〜255）。
struct GrayImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [Float]

    func value(_ x: Int, _ y: Int) -> Float {
        let cx: Int = max(0, min(width - 1, x))
        let cy: Int = max(0, min(height - 1, y))
        return pixels[cy * width + cx]
    }

    /// 双一次の補間で読む（はみ出したら端の色）。
    func sample(_ x: Float, _ y: Float) -> Float {
        let fx: Float = max(0, min(Float(width - 1), x))
        let fy: Float = max(0, min(Float(height - 1), y))
        let x0: Int = Int(fx)
        let y0: Int = Int(fy)
        let x1: Int = min(width - 1, x0 + 1)
        let y1: Int = min(height - 1, y0 + 1)
        let wx: Float = fx - Float(x0)
        let wy: Float = fy - Float(y0)
        let top: Float = pixels[y0 * width + x0] * (1 - wx) + pixels[y0 * width + x1] * wx
        let bottom: Float = pixels[y1 * width + x0] * (1 - wx) + pixels[y1 * width + x1] * wx
        return top * (1 - wy) + bottom * wy
    }

    /// 縦横半分。先に [1 2 1] でぼかしてから間引く（細かい模様が粗い段で別の模様に化けないように）。
    func half() -> GrayImage {
        let w: Int = max(1, width / 2)
        let h: Int = max(1, height / 2)
        var rows: [Float] = Array(repeating: 0, count: w * height)
        for y in 0..<height {
            for x in 0..<w {
                let cx: Int = 2 * x
                let sum: Float = value(cx - 1, y) + 2 * value(cx, y) + value(cx + 1, y)
                rows[y * w + x] = sum / 4
            }
        }
        var out: [Float] = Array(repeating: 0, count: w * h)
        for y in 0..<h {
            let cy: Int = 2 * y
            let up: Int = max(0, cy - 1)
            let down: Int = min(height - 1, cy + 1)
            for x in 0..<w {
                let sum: Float = rows[up * w + x] + 2 * rows[cy * w + x] + rows[down * w + x]
                out[y * w + x] = sum / 4
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }
}

/// 端末の動き解析（Vision）が使えないときの、自前の動きの推定（Q99, Q81: どの端末でもなめらかスローを作れるように）。
/// Lucas–Kanade 法を粗い段から細かい段へくり返す。計算は小さい絵（幅 256 まで）で行う。
enum OpticalFlowLK {
    static let workingWidth: Int = 256

    /// A から B への動き。戻り値の大きさは計算に使った絵の大きさ（入力より小さいことがある）。
    static func flow(from a: GrayImage, to b: GrayImage, iterations: Int = 4, radius: Int = 3) -> FlowField {
        var baseA: GrayImage = a
        var baseB: GrayImage = b
        while baseA.width > workingWidth {
            baseA = baseA.half()
            baseB = baseB.half()
        }
        var pyramidA: [GrayImage] = [baseA]
        var pyramidB: [GrayImage] = [baseB]
        while let last = pyramidA.last, min(last.width, last.height) >= 32 {
            pyramidA.append(last.half())
            pyramidB.append(pyramidB[pyramidB.count - 1].half())
        }
        var field: FlowField?
        for level in stride(from: pyramidA.count - 1, through: 0, by: -1) {
            let la: GrayImage = pyramidA[level]
            let lb: GrayImage = pyramidB[level]
            var current: FlowField = field.map { OpticalFlowLK.upsample($0, toWidth: la.width, height: la.height) } ?? FlowField(width: la.width, height: la.height)
            OpticalFlowLK.refine(&current, a: la, b: lb, iterations: iterations, radius: radius)
            current = OpticalFlowLK.smoothed(current)
            field = current
        }
        return field ?? FlowField(width: baseA.width, height: baseA.height)
    }

    /// 1 段分のくり返し。A の傾き（Ix・Iy）を使い、窓の中で 2x2 の式を解く。
    static func refine(_ field: inout FlowField, a: GrayImage, b: GrayImage, iterations: Int, radius: Int) {
        let w: Int = a.width
        let h: Int = a.height
        let n: Int = w * h
        var ix: [Float] = Array(repeating: 0, count: n)
        var iy: [Float] = Array(repeating: 0, count: n)
        for y in 0..<h {
            for x in 0..<w {
                ix[y * w + x] = (a.value(x + 1, y) - a.value(x - 1, y)) / 2
                iy[y * w + x] = (a.value(x, y + 1) - a.value(x, y - 1)) / 2
            }
        }
        var xx: [Float] = Array(repeating: 0, count: n)
        var xy: [Float] = Array(repeating: 0, count: n)
        var yy: [Float] = Array(repeating: 0, count: n)
        for i in 0..<n {
            xx[i] = ix[i] * ix[i]
            xy[i] = ix[i] * iy[i]
            yy[i] = iy[i] * iy[i]
        }
        let sxx: [Float] = OpticalFlowLK.boxSum(xx, w, h, radius)
        let sxy: [Float] = OpticalFlowLK.boxSum(xy, w, h, radius)
        let syy: [Float] = OpticalFlowLK.boxSum(yy, w, h, radius)
        var xt: [Float] = Array(repeating: 0, count: n)
        var yt: [Float] = Array(repeating: 0, count: n)
        for _ in 0..<iterations {
            for y in 0..<h {
                for x in 0..<w {
                    let i: Int = y * w + x
                    let u: Float = field.vectors[i * 2]
                    let v: Float = field.vectors[i * 2 + 1]
                    let it: Float = b.sample(Float(x) + u, Float(y) + v) - a.pixels[i]
                    xt[i] = ix[i] * it
                    yt[i] = iy[i] * it
                }
            }
            let sxt: [Float] = OpticalFlowLK.boxSum(xt, w, h, radius)
            let syt: [Float] = OpticalFlowLK.boxSum(yt, w, h, radius)
            for i in 0..<n {
                let det: Float = sxx[i] * syy[i] - sxy[i] * sxy[i]
                if det < 1e-3 { continue }
                let du: Float = (-syy[i] * sxt[i] + sxy[i] * syt[i]) / det
                let dv: Float = (sxy[i] * sxt[i] - sxx[i] * syt[i]) / det
                field.vectors[i * 2] += max(-4, min(4, du))
                field.vectors[i * 2 + 1] += max(-4, min(4, dv))
            }
        }
    }

    /// (2r+1)^2 の窓の合計（積分画像で計算する）。
    static func boxSum(_ values: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var integral: [Double] = Array(repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row: Double = 0
            for x in 0..<w {
                row += Double(values[y * w + x])
                integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
            }
        }
        var out: [Float] = Array(repeating: 0, count: w * h)
        for y in 0..<h {
            let y0: Int = max(0, y - r)
            let y1: Int = min(h, y + r + 1)
            for x in 0..<w {
                let x0: Int = max(0, x - r)
                let x1: Int = min(w, x + r + 1)
                let total: Double = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1] - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                out[y * w + x] = Float(total)
            }
        }
        return out
    }

    /// 粗い段の動きを細かい段の大きさに広げる（値も倍にする）。
    static func upsample(_ field: FlowField, toWidth w: Int, height h: Int) -> FlowField {
        var out = FlowField(width: w, height: h)
        let scaleX: Float = Float(w) / Float(max(1, field.width))
        let scaleY: Float = Float(h) / Float(max(1, field.height))
        for y in 0..<h {
            for x in 0..<w {
                let v: (dx: Float, dy: Float) = field.at(Int(Float(x) / scaleX), Int(Float(y) / scaleY))
                out.vectors[(y * w + x) * 2] = v.dx * scaleX
                out.vectors[(y * w + x) * 2 + 1] = v.dy * scaleY
            }
        }
        return out
    }

    /// 3x3 の平均で、とびぬけた値をならす。
    static func smoothed(_ field: FlowField) -> FlowField {
        var out: FlowField = field
        let w: Int = field.width
        let h: Int = field.height
        for y in 0..<h {
            for x in 0..<w {
                var sx: Float = 0
                var sy: Float = 0
                for j in -1...1 {
                    for i in -1...1 {
                        let v: (dx: Float, dy: Float) = field.at(x + i, y + j)
                        sx += v.dx
                        sy += v.dy
                    }
                }
                out.vectors[(y * w + x) * 2] = sx / 9
                out.vectors[(y * w + x) * 2 + 1] = sy / 9
            }
        }
        return out
    }
}
