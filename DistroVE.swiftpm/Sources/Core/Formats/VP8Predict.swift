import Foundation

// VP8 の予測・逆変換・ループフィルター（RFC 6386 の参照用の解読器 dixie の predict.c・idct_add.c・dixie_loopfilter.c を移植）。
// 著作権表示とライセンスは VP8Tables.swift の先頭を参照（BSD 3 条項。Google Inc.）。
// 型の確認を速くするため、画素は px() で Int にしてから計算する。

/// 画素を Int で読む。
@inline(__always) func vp8px(_ p: UnsafeMutablePointer<UInt8>, _ i: Int) -> Int {
    return Int(p[i])
}

/// 0〜255 に収める。
@inline(__always) func vp8clamp(_ v: Int) -> UInt8 {
    if v < 0 { return 0 }
    if v > 255 { return 255 }
    return UInt8(v)
}

/// (a + 2b + c + 2) >> 2
@inline(__always) func vp8avg3(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let sum: Int = a + b + b + c + 2
    return sum >> 2
}

/// (a + b + 1) >> 1
@inline(__always) func vp8avg2(_ a: Int, _ b: Int) -> Int {
    let sum: Int = a + b + 1
    return sum >> 1
}

enum VP8Predict {
    /// 6 タップのフィルター [8][6]（版 0）
    static let sixtap: [Int] = [
        0, 0, 128, 0, 0, 0,
        0, -6, 123, 12, -1, 0,
        2, -11, 108, 36, -8, 1,
        0, -9, 93, 50, -6, 0,
        3, -16, 77, 77, -16, 3,
        0, -6, 50, 93, -9, 0,
        1, -8, 36, 108, -11, 2,
        0, -1, 12, 123, -6, 0
    ]

    /// 双一次のフィルター [8][6]（版 1〜3）
    static let bilinear: [Int] = [
        0, 0, 128, 0, 0, 0,
        0, 0, 112, 16, 0, 0,
        0, 0, 96, 32, 0, 0,
        0, 0, 80, 48, 0, 0,
        0, 0, 64, 64, 0, 0,
        0, 0, 48, 80, 0, 0,
        0, 0, 32, 96, 0, 0,
        0, 0, 16, 112, 0, 0
    ]

    // MARK: 画面の端（fixup_left・fixup_above）

    /// 左の列の外は 129。DC_PRED では上の行を写す（ただし 1 行目は 129）。
    static func fixupLeft(_ predict: UnsafeMutablePointer<UInt8>, _ width: Int, _ stride: Int, _ row: Int, _ mode: Int) {
        let left: UnsafeMutablePointer<UInt8> = predict - 1
        if mode == VP8Decoder.dcPred && row > 0 {
            let above: UnsafeMutablePointer<UInt8> = predict - stride
            for i in 0..<width {
                left[i * stride] = above[i]
            }
        } else {
            for i in -1..<width {
                left[i * stride] = 129
            }
        }
    }

    /// 上の行の外は 127。DC_PRED では左の列を写す（ただし 1 列目は 127）。右上の 4 画素も 127。
    static func fixupAbove(_ predict: UnsafeMutablePointer<UInt8>, _ width: Int, _ stride: Int, _ col: Int, _ mode: Int) {
        let above: UnsafeMutablePointer<UInt8> = predict - stride
        if mode == VP8Decoder.dcPred && col > 0 {
            let left: UnsafeMutablePointer<UInt8> = predict - 1
            for i in 0..<width {
                above[i] = left[i * stride]
            }
        } else {
            for i in -1..<width {
                above[i] = 127
            }
        }
        for i in 0..<4 {
            above[width + i] = 127
        }
    }

    // MARK: イントラ予測（16x16・8x8）

    static func lumaIntra(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ mode: Int) {
        predictBlock(p, stride, 16, mode)
    }

    static func chromaIntra(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ mode: Int) {
        predictBlock(p, stride, 8, mode)
    }

    private static func predictBlock(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ n: Int, _ mode: Int) {
        switch mode {
        case VP8Decoder.vPred:
            let above: UnsafeMutablePointer<UInt8> = p - stride
            for i in 0..<n {
                for j in 0..<n {
                    p[i * stride + j] = above[j]
                }
            }
        case VP8Decoder.hPred:
            for i in 0..<n {
                let value: UInt8 = p[i * stride - 1]
                for j in 0..<n {
                    p[i * stride + j] = value
                }
            }
        case VP8Decoder.tmPred:
            trueMotion(p, stride, n)
        default:
            dc(p, stride, n)
        }
    }

    private static func dc(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ n: Int) {
        var sum: Int = 0
        for i in 0..<n {
            sum += vp8px(p, i * stride - 1)
            sum += vp8px(p, i - stride)
        }
        let shift: Int = n == 16 ? 5 : (n == 8 ? 4 : 3)
        let value: UInt8 = UInt8((sum + n) >> shift)
        for i in 0..<n {
            for j in 0..<n {
                p[i * stride + j] = value
            }
        }
    }

    private static func trueMotion(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ n: Int) {
        let corner: Int = vp8px(p, -stride - 1)
        for i in 0..<n {
            let left: Int = vp8px(p, i * stride - 1)
            for j in 0..<n {
                let above: Int = vp8px(p, j - stride)
                p[i * stride + j] = vp8clamp(left + above - corner)
            }
        }
    }

    // MARK: 4x4 の予測（B_PRED）

    /// 16 個の 4x4（b_pred）。右の列の右上は、マクロブロックの右上の 4 画素を写して使う（copy_down）。
    static func bPred(_ predict: UnsafeMutablePointer<UInt8>, _ stride: Int, _ modes: UnsafeBufferPointer<UInt8>, _ base: Int,
                      _ coeffs: UnsafeMutablePointer<Int16>) {
        let source: UnsafeMutablePointer<UInt8> = predict + 16 - stride
        for line in [3, 7, 11] {
            let target: UnsafeMutablePointer<UInt8> = predict + 16 + line * stride
            for i in 0..<4 {
                target[i] = source[i]
            }
        }
        for i in 0..<16 {
            let block: UnsafeMutablePointer<UInt8> = predict + (i & 3) * 4 + (i >> 2) * 4 * stride
            subblock(block, stride, Int(modes[base + i]))
            idctAdd(block, stride, block, stride, coeffs + i * 16)
        }
    }

    /// 4x4 の 1 行を書く。
    @inline(__always) private static func row(_ p: UnsafeMutablePointer<UInt8>, _ r: Int, _ stride: Int, _ v0: Int, _ v1: Int, _ v2: Int, _ v3: Int) {
        let line: UnsafeMutablePointer<UInt8> = p + r * stride
        line[0] = UInt8(truncatingIfNeeded: v0)
        line[1] = UInt8(truncatingIfNeeded: v1)
        line[2] = UInt8(truncatingIfNeeded: v2)
        line[3] = UInt8(truncatingIfNeeded: v3)
    }

    private static func subblock(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ mode: Int) {
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 13) { (buffer: UnsafeMutableBufferPointer<Int>) in
            guard let e = buffer.baseAddress else { return }
            // e[0..7]: 上（右上を含む）、e[8..11]: 左、e[12]: 左上
            for i in 0..<8 {
                e[i] = vp8px(p, i - stride)
            }
            for i in 0..<4 {
                e[8 + i] = vp8px(p, i * stride - 1)
            }
            e[12] = vp8px(p, -stride - 1)
            subblock(p, stride, mode, e)
        }
    }

    private static func subblock(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ mode: Int, _ e: UnsafeMutablePointer<Int>) {
        let c: Int = e[12]
        switch mode {
        case 0:
            var sum: Int = 4
            for i in 0..<4 {
                sum += e[i] + e[8 + i]
            }
            let value: Int = sum >> 3
            for r in 0..<4 {
                row(p, r, stride, value, value, value, value)
            }
        case 1:
            for r in 0..<4 {
                let left: Int = e[8 + r]
                let line: UnsafeMutablePointer<UInt8> = p + r * stride
                for k in 0..<4 {
                    line[k] = vp8clamp(left + e[k] - c)
                }
            }
        case 2:
            let v0: Int = vp8avg3(c, e[0], e[1])
            let v1: Int = vp8avg3(e[0], e[1], e[2])
            let v2: Int = vp8avg3(e[1], e[2], e[3])
            let v3: Int = vp8avg3(e[2], e[3], e[4])
            for r in 0..<4 {
                row(p, r, stride, v0, v1, v2, v3)
            }
        case 3:
            let r0: Int = vp8avg3(c, e[8], e[9])
            let r1: Int = vp8avg3(e[8], e[9], e[10])
            let r2: Int = vp8avg3(e[9], e[10], e[11])
            let r3: Int = vp8avg3(e[10], e[11], e[11])
            row(p, 0, stride, r0, r0, r0, r0)
            row(p, 1, stride, r1, r1, r1, r1)
            row(p, 2, stride, r2, r2, r2, r2)
            row(p, 3, stride, r3, r3, r3, r3)
        case 4:
            downLeft(p, stride, e)
        case 5:
            downRight(p, stride, e)
        case 6:
            verticalRight(p, stride, e)
        case 7:
            verticalLeft(p, stride, e)
        case 8:
            horizontalDown(p, stride, e)
        default:
            horizontalUp(p, stride, e)
        }
    }

    /// B_LD_PRED
    private static func downLeft(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ e: UnsafeMutablePointer<Int>) {
        let d0: Int = vp8avg3(e[0], e[1], e[2])
        let d1: Int = vp8avg3(e[1], e[2], e[3])
        let d2: Int = vp8avg3(e[2], e[3], e[4])
        let d3: Int = vp8avg3(e[3], e[4], e[5])
        let d4: Int = vp8avg3(e[4], e[5], e[6])
        let d5: Int = vp8avg3(e[5], e[6], e[7])
        let d6: Int = vp8avg3(e[6], e[7], e[7])
        row(p, 0, stride, d0, d1, d2, d3)
        row(p, 1, stride, d1, d2, d3, d4)
        row(p, 2, stride, d2, d3, d4, d5)
        row(p, 3, stride, d3, d4, d5, d6)
    }

    /// B_RD_PRED
    private static func downRight(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ e: UnsafeMutablePointer<Int>) {
        let c: Int = e[12]
        let p0: Int = vp8avg3(e[8], c, e[0])
        let p1: Int = vp8avg3(c, e[0], e[1])
        let p2: Int = vp8avg3(e[0], e[1], e[2])
        let p3: Int = vp8avg3(e[1], e[2], e[3])
        let p4: Int = vp8avg3(e[9], e[8], c)
        let p5: Int = vp8avg3(e[10], e[9], e[8])
        let p6: Int = vp8avg3(e[11], e[10], e[9])
        row(p, 0, stride, p0, p1, p2, p3)
        row(p, 1, stride, p4, p0, p1, p2)
        row(p, 2, stride, p5, p4, p0, p1)
        row(p, 3, stride, p6, p5, p4, p0)
    }

    /// B_VR_PRED
    private static func verticalRight(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ e: UnsafeMutablePointer<Int>) {
        let c: Int = e[12]
        let p0: Int = vp8avg2(c, e[0])
        let p1: Int = vp8avg2(e[0], e[1])
        let p2: Int = vp8avg2(e[1], e[2])
        let p3: Int = vp8avg2(e[2], e[3])
        let p4: Int = vp8avg3(e[8], c, e[0])
        let p5: Int = vp8avg3(c, e[0], e[1])
        let p6: Int = vp8avg3(e[0], e[1], e[2])
        let p7: Int = vp8avg3(e[1], e[2], e[3])
        let p8: Int = vp8avg3(e[9], e[8], c)
        let p9: Int = vp8avg3(e[10], e[9], e[8])
        row(p, 0, stride, p0, p1, p2, p3)
        row(p, 1, stride, p4, p5, p6, p7)
        row(p, 2, stride, p8, p0, p1, p2)
        row(p, 3, stride, p9, p4, p5, p6)
    }

    /// B_VL_PRED
    private static func verticalLeft(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ e: UnsafeMutablePointer<Int>) {
        let p0: Int = vp8avg2(e[0], e[1])
        let p1: Int = vp8avg2(e[1], e[2])
        let p2: Int = vp8avg2(e[2], e[3])
        let p3: Int = vp8avg2(e[3], e[4])
        let p4: Int = vp8avg3(e[0], e[1], e[2])
        let p5: Int = vp8avg3(e[1], e[2], e[3])
        let p6: Int = vp8avg3(e[2], e[3], e[4])
        let p7: Int = vp8avg3(e[3], e[4], e[5])
        let p8: Int = vp8avg3(e[4], e[5], e[6])
        let p9: Int = vp8avg3(e[5], e[6], e[7])
        row(p, 0, stride, p0, p1, p2, p3)
        row(p, 1, stride, p4, p5, p6, p7)
        row(p, 2, stride, p1, p2, p3, p8)
        row(p, 3, stride, p5, p6, p7, p9)
    }

    /// B_HD_PRED
    private static func horizontalDown(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ e: UnsafeMutablePointer<Int>) {
        let c: Int = e[12]
        let p0: Int = vp8avg2(e[8], c)
        let p1: Int = vp8avg3(e[8], c, e[0])
        let p2: Int = vp8avg3(c, e[0], e[1])
        let p3: Int = vp8avg3(e[0], e[1], e[2])
        let p4: Int = vp8avg2(e[9], e[8])
        let p5: Int = vp8avg3(e[9], e[8], c)
        let p6: Int = vp8avg2(e[10], e[9])
        let p7: Int = vp8avg3(e[10], e[9], e[8])
        let p8: Int = vp8avg2(e[11], e[10])
        let p9: Int = vp8avg3(e[11], e[10], e[9])
        row(p, 0, stride, p0, p1, p2, p3)
        row(p, 1, stride, p4, p5, p0, p1)
        row(p, 2, stride, p6, p7, p4, p5)
        row(p, 3, stride, p8, p9, p6, p7)
    }

    /// B_HU_PRED
    private static func horizontalUp(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ e: UnsafeMutablePointer<Int>) {
        let p0: Int = vp8avg2(e[8], e[9])
        let p1: Int = vp8avg3(e[8], e[9], e[10])
        let p2: Int = vp8avg2(e[9], e[10])
        let p3: Int = vp8avg3(e[9], e[10], e[11])
        let p4: Int = vp8avg2(e[10], e[11])
        let p5: Int = vp8avg3(e[10], e[11], e[11])
        let p6: Int = e[11]
        row(p, 0, stride, p0, p1, p2, p3)
        row(p, 1, stride, p2, p3, p4, p5)
        row(p, 2, stride, p4, p5, p6, p6)
        row(p, 3, stride, p6, p6, p6, p6)
    }

    // MARK: 逆変換（idct_add.c）

    /// 2 次の変換（WHT）を戻して、16 個の輝度のブロックの DC にする。
    static func walshIntoDC(_ coeffs: UnsafeMutablePointer<Int16>) {
        let input: UnsafeMutablePointer<Int16> = coeffs + 24 * 16
        var mid: [Int] = Array(repeating: 0, count: 16)
        for i in 0..<4 {
            let i0: Int = Int(input[i])
            let i4: Int = Int(input[4 + i])
            let i8: Int = Int(input[8 + i])
            let i12: Int = Int(input[12 + i])
            let a1: Int = i0 + i12
            let b1: Int = i4 + i8
            let c1: Int = i4 - i8
            let d1: Int = i0 - i12
            mid[i] = Int(Int16(truncatingIfNeeded: a1 + b1))
            mid[4 + i] = Int(Int16(truncatingIfNeeded: c1 + d1))
            mid[8 + i] = Int(Int16(truncatingIfNeeded: a1 - b1))
            mid[12 + i] = Int(Int16(truncatingIfNeeded: d1 - c1))
        }
        for i in 0..<4 {
            let r0: Int = mid[i * 4]
            let r1: Int = mid[i * 4 + 1]
            let r2: Int = mid[i * 4 + 2]
            let r3: Int = mid[i * 4 + 3]
            let a1: Int = r0 + r3
            let b1: Int = r1 + r2
            let c1: Int = r1 - r2
            let d1: Int = r0 - r3
            let a2: Int = a1 + b1
            let b2: Int = c1 + d1
            let c2: Int = a1 - b1
            let d2: Int = d1 - c1
            coeffs[(i * 4) * 16] = Int16(truncatingIfNeeded: (a2 + 3) >> 3)
            coeffs[(i * 4 + 1) * 16] = Int16(truncatingIfNeeded: (b2 + 3) >> 3)
            coeffs[(i * 4 + 2) * 16] = Int16(truncatingIfNeeded: (c2 + 3) >> 3)
            coeffs[(i * 4 + 3) * 16] = Int16(truncatingIfNeeded: (d2 + 3) >> 3)
        }
    }

    @inline(__always) private static func mulSin(_ x: Int) -> Int {
        let product: Int = x * 35468
        return product >> 16
    }

    @inline(__always) private static func mulCos(_ x: Int) -> Int {
        let product: Int = x * 20091
        return x + (product >> 16)
    }

    /// 4x4 の逆 DCT を予測に足して recon に書く（predict と recon は同じ所でもよい）。
    static func idctAdd(_ recon: UnsafeMutablePointer<UInt8>, _ reconStride: Int, _ predict: UnsafeMutablePointer<UInt8>, _ predictStride: Int,
                        _ coeffs: UnsafeMutablePointer<Int16>) {
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 16) { (buffer: UnsafeMutableBufferPointer<Int>) in
            guard let mid = buffer.baseAddress else { return }
            idctAdd(recon, reconStride, predict, predictStride, coeffs, mid)
        }
    }

    private static func idctAdd(_ recon: UnsafeMutablePointer<UInt8>, _ reconStride: Int, _ predict: UnsafeMutablePointer<UInt8>, _ predictStride: Int,
                                _ coeffs: UnsafeMutablePointer<Int16>, _ mid: UnsafeMutablePointer<Int>) {
        for i in 0..<4 {
            let i0: Int = Int(coeffs[i])
            let i4: Int = Int(coeffs[4 + i])
            let i8: Int = Int(coeffs[8 + i])
            let i12: Int = Int(coeffs[12 + i])
            let a1: Int = i0 + i8
            let b1: Int = i0 - i8
            let c1: Int = mulSin(i4) - mulCos(i12)
            let d1: Int = mulCos(i4) + mulSin(i12)
            mid[i] = Int(Int16(truncatingIfNeeded: a1 + d1))
            mid[12 + i] = Int(Int16(truncatingIfNeeded: a1 - d1))
            mid[4 + i] = Int(Int16(truncatingIfNeeded: b1 + c1))
            mid[8 + i] = Int(Int16(truncatingIfNeeded: b1 - c1))
        }
        for r in 0..<4 {
            let x0: Int = mid[r * 4]
            let x1: Int = mid[r * 4 + 1]
            let x2: Int = mid[r * 4 + 2]
            let x3: Int = mid[r * 4 + 3]
            let a1: Int = x0 + x2
            let b1: Int = x0 - x2
            let c1: Int = mulSin(x1) - mulCos(x3)
            let d1: Int = mulCos(x1) + mulSin(x3)
            let out: UnsafeMutablePointer<UInt8> = recon + r * reconStride
            let pred: UnsafeMutablePointer<UInt8> = predict + r * predictStride
            out[0] = vp8clamp(vp8px(pred, 0) + ((a1 + d1 + 4) >> 3))
            out[3] = vp8clamp(vp8px(pred, 3) + ((a1 - d1 + 4) >> 3))
            out[1] = vp8clamp(vp8px(pred, 1) + ((b1 + c1 + 4) >> 3))
            out[2] = vp8clamp(vp8px(pred, 2) + ((b1 - c1 + 4) >> 3))
        }
    }

    /// 16x16 の輝度に 16 個の逆 DCT を足す。
    static func addLuma(_ p: UnsafeMutablePointer<UInt8>, _ stride: Int, _ coeffs: UnsafeMutablePointer<Int16>) {
        for i in 0..<16 {
            let block: UnsafeMutablePointer<UInt8> = p + (i & 3) * 4 + (i >> 2) * 4 * stride
            idctAdd(block, stride, block, stride, coeffs + i * 16)
        }
    }

    /// 8x8 の色差 2 面に 4 個ずつ足す。
    static func addChroma(_ u: UnsafeMutablePointer<UInt8>, _ v: UnsafeMutablePointer<UInt8>, _ stride: Int, _ coeffs: UnsafeMutablePointer<Int16>) {
        for i in 0..<4 {
            let offset: Int = (i & 1) * 4 + (i >> 1) * 4 * stride
            idctAdd(u + offset, stride, u + offset, stride, coeffs + (16 + i) * 16)
            idctAdd(v + offset, stride, v + offset, stride, coeffs + (20 + i) * 16)
        }
    }

    // MARK: 動き補償（predict.c）

    /// 4x4 を 1 つ、参照の絵から予測して係数を足す。画面の外を読むときは端をくり返した 9x9 を作る（build_mc_border）。
    static func interBlock(_ plane: UnsafeMutablePointer<UInt8>, _ reference: UnsafeMutablePointer<UInt8>, _ stride: Int,
                           _ bx: Int, _ by: Int, _ w: Int, _ h: Int, _ mv: VP8MV, _ filters: [Int], _ coeffs: UnsafeMutablePointer<Int16>) {
        let output: UnsafeMutablePointer<UInt8> = plane + by * stride + bx
        let mvx: Int = Int(mv.x)
        let mvy: Int = Int(mv.y)
        if mvx == 0 && mvy == 0 {
            idctAdd(output, stride, reference + by * stride + bx, stride, coeffs)
            return
        }
        let fx: Int = bx + (mvx >> 3)
        let fy: Int = by + (mvy >> 3)
        let mx: Int = mvx & 7
        let my: Int = mvy & 7
        let outside: Bool = fx < 2 || fx + 6 >= w || fy < 2 || fy + 6 >= h
        if !outside {
            let source: UnsafeMutablePointer<UInt8> = reference + fy * stride + fx
            predictAndAdd(output, stride, source, stride, mx, my, filters, coeffs)
            return
        }
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 16 * 9) { (buffer: UnsafeMutableBufferPointer<UInt8>) in
            guard let scratch = buffer.baseAddress else { return }
            for r in 0..<9 {
                let sy: Int = max(0, min(h - 1, fy - 2 + r))
                for c in 0..<9 {
                    let sx: Int = max(0, min(w - 1, fx - 2 + c))
                    scratch[r * 16 + c] = reference[sy * stride + sx]
                }
            }
            predictAndAdd(output, stride, scratch + 2 * 16 + 2, 16, mx, my, filters, coeffs)
        }
    }

    private static func predictAndAdd(_ output: UnsafeMutablePointer<UInt8>, _ stride: Int, _ source: UnsafeMutablePointer<UInt8>, _ sourceStride: Int,
                                      _ mx: Int, _ my: Int, _ filters: [Int], _ coeffs: UnsafeMutablePointer<Int16>) {
        if mx == 0 && my == 0 {
            idctAdd(output, stride, source, sourceStride, coeffs)
            return
        }
        sixtap(output, stride, source, sourceStride, mx, my, filters)
        idctAdd(output, stride, output, stride, coeffs)
    }

    /// 2 段の 6 タップ（sixtap_2d）。横に 9 行分かけてから、縦にかける。
    private static func sixtap(_ output: UnsafeMutablePointer<UInt8>, _ outStride: Int, _ source: UnsafeMutablePointer<UInt8>, _ sourceStride: Int,
                               _ mx: Int, _ my: Int, _ filters: [Int]) {
        let h0: Int = filters[mx * 6]
        let h1: Int = filters[mx * 6 + 1]
        let h2: Int = filters[mx * 6 + 2]
        let h3: Int = filters[mx * 6 + 3]
        let h4: Int = filters[mx * 6 + 4]
        let h5: Int = filters[mx * 6 + 5]
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 4 * 9) { (buffer: UnsafeMutableBufferPointer<Int>) in
            guard let temp = buffer.baseAddress else { return }
            sixtapPasses(output, outStride, source, sourceStride, (h0, h1, h2, h3, h4, h5), my, filters, temp)
        }
    }

    private static func sixtapPasses(_ output: UnsafeMutablePointer<UInt8>, _ outStride: Int, _ source: UnsafeMutablePointer<UInt8>, _ sourceStride: Int,
                                     _ h: (Int, Int, Int, Int, Int, Int), _ my: Int, _ filters: [Int], _ temp: UnsafeMutablePointer<Int>) {
        let h0: Int = h.0
        let h1: Int = h.1
        let h2: Int = h.2
        let h3: Int = h.3
        let h4: Int = h.4
        let h5: Int = h.5
        for r in 0..<9 {
            let row: UnsafeMutablePointer<UInt8> = source + (r - 2) * sourceStride
            for c in 0..<4 {
                var t: Int = 64
                t += vp8px(row, c - 2) * h0
                t += vp8px(row, c - 1) * h1
                t += vp8px(row, c) * h2
                t += vp8px(row, c + 1) * h3
                t += vp8px(row, c + 2) * h4
                t += vp8px(row, c + 3) * h5
                temp[r * 4 + c] = Int(vp8clamp(t >> 7))
            }
        }
        let v0: Int = filters[my * 6]
        let v1: Int = filters[my * 6 + 1]
        let v2: Int = filters[my * 6 + 2]
        let v3: Int = filters[my * 6 + 3]
        let v4: Int = filters[my * 6 + 4]
        let v5: Int = filters[my * 6 + 5]
        for r in 0..<4 {
            for c in 0..<4 {
                let base: Int = (r + 2) * 4 + c
                var t: Int = 64
                t += temp[base - 8] * v0
                t += temp[base - 4] * v1
                t += temp[base] * v2
                t += temp[base + 4] * v3
                t += temp[base + 8] * v4
                t += temp[base + 12] * v5
                output[r * outStride + c] = vp8clamp(t >> 7)
            }
        }
    }
}

/// ループフィルター（dixie_loopfilter.c）。p は境目の向こう側の最初の画素（q0）。across は境目をまたぐ向きの間隔、along は境目に沿う向きの間隔。
enum VP8LoopFilter {
    @inline(__always) private static func s8(_ x: Int) -> Int {
        return x < -128 ? -128 : (x > 127 ? 127 : x)
    }

    @inline(__always) private static func u8(_ x: Int) -> UInt8 {
        return vp8clamp(x)
    }

    @inline(__always) private static func simpleThreshold(_ p: UnsafeMutablePointer<UInt8>, _ a: Int, _ limit: Int) -> Bool {
        let p0: Int = vp8px(p, -a)
        let q0: Int = vp8px(p, 0)
        let p1: Int = vp8px(p, -2 * a)
        let q1: Int = vp8px(p, a)
        let value: Int = abs(p0 - q0) * 2 + (abs(p1 - q1) >> 1)
        return value <= limit
    }

    @inline(__always) private static func normalThreshold(_ p: UnsafeMutablePointer<UInt8>, _ a: Int, _ e: Int, _ i: Int) -> Bool {
        if !simpleThreshold(p, a, 2 * e + i) { return false }
        let p3: Int = vp8px(p, -4 * a)
        let p2: Int = vp8px(p, -3 * a)
        let p1: Int = vp8px(p, -2 * a)
        let p0: Int = vp8px(p, -a)
        let q0: Int = vp8px(p, 0)
        let q1: Int = vp8px(p, a)
        let q2: Int = vp8px(p, 2 * a)
        let q3: Int = vp8px(p, 3 * a)
        if abs(p3 - p2) > i || abs(p2 - p1) > i || abs(p1 - p0) > i { return false }
        return abs(q3 - q2) <= i && abs(q2 - q1) <= i && abs(q1 - q0) <= i
    }

    @inline(__always) private static func highVariance(_ p: UnsafeMutablePointer<UInt8>, _ a: Int, _ threshold: Int) -> Bool {
        let p1: Int = vp8px(p, -2 * a)
        let p0: Int = vp8px(p, -a)
        let q0: Int = vp8px(p, 0)
        let q1: Int = vp8px(p, a)
        return abs(p1 - p0) > threshold || abs(q1 - q0) > threshold
    }

    private static func common(_ p: UnsafeMutablePointer<UInt8>, _ a: Int, _ outer: Bool) {
        let p1: Int = vp8px(p, -2 * a)
        let p0: Int = vp8px(p, -a)
        let q0: Int = vp8px(p, 0)
        let q1: Int = vp8px(p, a)
        var value: Int = 3 * (q0 - p0)
        if outer { value += s8(p1 - q1) }
        value = s8(value)
        let f1: Int = (value + 4 > 127 ? 127 : value + 4) >> 3
        let f2: Int = (value + 3 > 127 ? 127 : value + 3) >> 3
        p[-a] = u8(p0 + f2)
        p[0] = u8(q0 - f1)
        if !outer {
            let half: Int = (f1 + 1) >> 1
            p[-2 * a] = u8(p1 + half)
            p[a] = u8(q1 - half)
        }
    }

    private static func mbFilter(_ p: UnsafeMutablePointer<UInt8>, _ a: Int) {
        let p2: Int = vp8px(p, -3 * a)
        let p1: Int = vp8px(p, -2 * a)
        let p0: Int = vp8px(p, -a)
        let q0: Int = vp8px(p, 0)
        let q1: Int = vp8px(p, a)
        let q2: Int = vp8px(p, 2 * a)
        let w: Int = s8(s8(p1 - q1) + 3 * (q0 - p0))
        let a0: Int = (27 * w + 63) >> 7
        p[-a] = u8(p0 + a0)
        p[0] = u8(q0 - a0)
        let a1: Int = (18 * w + 63) >> 7
        p[-2 * a] = u8(p1 + a1)
        p[a] = u8(q1 - a1)
        let a2: Int = (9 * w + 63) >> 7
        p[-3 * a] = u8(p2 + a2)
        p[2 * a] = u8(q2 - a2)
    }

    /// マクロブロックの境目（filter_mb_v_edge・filter_mb_h_edge）。
    static func mbEdge(_ start: UnsafeMutablePointer<UInt8>, _ across: Int, _ along: Int, _ edge: Int, _ interior: Int, _ hev: Int, _ count: Int) {
        for k in 0..<count {
            let p: UnsafeMutablePointer<UInt8> = start + k * along
            if normalThreshold(p, across, edge, interior) {
                if highVariance(p, across, hev) {
                    common(p, across, true)
                } else {
                    mbFilter(p, across)
                }
            }
        }
    }

    /// 4x4 の境目（filter_subblock_v_edge・filter_subblock_h_edge）。
    static func subblockEdge(_ start: UnsafeMutablePointer<UInt8>, _ across: Int, _ along: Int, _ edge: Int, _ interior: Int, _ hev: Int, _ count: Int) {
        for k in 0..<count {
            let p: UnsafeMutablePointer<UInt8> = start + k * along
            if normalThreshold(p, across, edge, interior) {
                common(p, across, highVariance(p, across, hev))
            }
        }
    }

    /// 簡易フィルター（輝度だけ・16 画素）。
    static func simple(_ start: UnsafeMutablePointer<UInt8>, _ across: Int, _ along: Int, _ limit: Int) {
        for k in 0..<16 {
            let p: UnsafeMutablePointer<UInt8> = start + k * along
            if simpleThreshold(p, across, limit) {
                common(p, across, true)
            }
        }
    }
}
