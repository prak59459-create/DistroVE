import Foundation

/// VP8 の解読（Q71: WebM の映像。iPad には VP8 の解読器が無いため Swift で書く）。
/// RFC 6386「VP8 Data Format and Decoding Guide」の参照用の解読器（dixie）を移植した。出力は I420（Y・U・V の 3 面）。
/// 著作権表示とライセンスは VP8Tables.swift の先頭を参照（BSD 3 条項。Google Inc.）。
///
/// 移植で変えた所：
/// - マクロブロックごとに「モード → 係数 → 予測と足し合わせ」を続けて行う（dixie は 1 行ずつ。結果は同じ）
/// - ループフィルターは全部のマクロブロックを作ったあとにフレーム全体へかける（仕様の書き方。結果は同じ）
/// - 動き補償で画面の外を読むときは、端の画素をくり返した 9x9 を作ってから読む（dixie の build_mc_border と同じ）
/// - キーフレームの clamping_type が 1 でも読む（libvpx と同じく、常に 0〜255 に収める）
final class VP8Decoder {
    enum DecodeError: Error, Equatable {
        case invalid(String)
        case unsupported(String)
    }

    /// 表示する大きさの I420。
    struct Image {
        let width: Int
        let height: Int
        let y: [UInt8]
        let u: [UInt8]
        let v: [UInt8]
        var chromaWidth: Int { return (width + 1) / 2 }
        var chromaHeight: Int { return (height + 1) / 2 }
    }

    // モード（dixie の enum prediction_mode と同じ番号）
    static let dcPred: Int = 0
    static let vPred: Int = 1
    static let hPred: Int = 2
    static let tmPred: Int = 3
    static let bPred: Int = 4
    static let nearestMV: Int = 5
    static let nearMV: Int = 6
    static let zeroMV: Int = 7
    static let newMV: Int = 8
    static let splitMV: Int = 9
    static let left4x4: Int = 10
    static let above4x4: Int = 11
    static let zero4x4: Int = 12
    static let new4x4: Int = 13

    // 参照フレーム
    static let currentFrame: Int = 0
    static let lastFrame: Int = 1
    static let goldenFrame: Int = 2
    static let altrefFrame: Int = 3

    private(set) var width: Int = 0
    private(set) var height: Int = 0
    private var mbCols: Int = 0
    private var mbRows: Int = 0
    private var version: Int = 0
    private var keyframe: Bool = false

    // 見出し（フレームをまたいで残るもの）
    private var segmentationEnabled: Bool = false
    private var segmentUpdateMap: Bool = false
    private var segmentAbsolute: Bool = false
    private var segmentTreeProbs: [Int] = [255, 255, 255]
    private var segmentQuant: [Int] = [0, 0, 0, 0]
    private var segmentFilter: [Int] = [0, 0, 0, 0]
    private var filterSimple: Bool = false
    private var filterLevel: Int = 0
    private var sharpness: Int = 0
    private var filterDeltas: Bool = false
    private var refDelta: [Int] = [0, 0, 0, 0]
    private var modeDelta: [Int] = [0, 0, 0, 0]
    private var qIndex: Int = 0
    private var y1DC: Int = 0
    private var y2DC: Int = 0
    private var y2AC: Int = 0
    private var uvDC: Int = 0
    private var uvAC: Int = 0
    private var signBias: [Bool] = [false, false, false, false]

    private var entropy = VP8Entropy()
    private var saved: VP8Entropy?

    // マクロブロックの情報（左に 1 列・上に 1 行の縁つき。縁は 0 のまま＝DC_PRED・現在のフレーム・動きなし）
    private var info: [VP8MacroblockInfo] = []
    private var subModes: [UInt8] = []
    private var subMVs: [VP8MV] = []
    private var aboveContext: [UInt8] = []
    private var coefficients: [Int16] = Array(repeating: 0, count: 25 * 16)

    private var references: [VP8Picture?] = [nil, nil, nil, nil]
    private var pool: [VP8Picture] = []
    private var lastShown: Image?

    init() {}

    private func index(_ row: Int, _ col: Int) -> Int {
        return (row + 1) * (mbCols + 1) + (col + 1)
    }

    // MARK: フレーム

    /// 1 フレームを解読する。表示するフレームなら画像を返す（altref のように表示しないものは nil）。
    func decode(_ data: Data) throws -> Image? {
        if data.isEmpty { return lastShown }
        let bytes: [UInt8] = [UInt8](data)
        guard bytes.count >= 3 else { throw DecodeError.invalid("VP8 のフレームが短すぎます") }
        let b0: Int = Int(bytes[0])
        let b1: Int = Int(bytes[1])
        let b2: Int = Int(bytes[2])
        let raw: Int = b0 | (b1 << 8) | (b2 << 16)
        keyframe = raw & 1 == 0
        version = (raw >> 1) & 7
        let shown: Bool = (raw >> 4) & 1 == 1
        let firstSize: Int = (raw >> 5) & 0x7FFFF
        var offset: Int = 3
        if keyframe {
            guard bytes.count >= 10, bytes[3] == 0x9D, bytes[4] == 0x01, bytes[5] == 0x2A else {
                throw DecodeError.invalid("VP8 のキーフレームの印がありません")
            }
            let w0: Int = Int(bytes[6])
            let w1: Int = Int(bytes[7])
            let h0: Int = Int(bytes[8])
            let h1: Int = Int(bytes[9])
            let w: Int = (w0 | (w1 << 8)) & 0x3FFF
            let h: Int = (h0 | (h1 << 8)) & 0x3FFF
            guard w > 0, h > 0 else { throw DecodeError.invalid("VP8 の大きさが 0 です") }
            offset = 10
            if w != width || h != height || info.isEmpty {
                allocate(width: w, height: h)
            }
        } else if info.isEmpty {
            throw DecodeError.invalid("VP8 の最初のフレームがキーフレームではありません")
        }
        if version > 3 { throw DecodeError.unsupported("VP8 の版 \(version) は読めません") }
        guard offset + firstSize <= bytes.count else { throw DecodeError.invalid("VP8 の最初の区切りが途中で切れています") }
        var header = VP8BoolDecoder(bytes, start: offset, size: firstSize)
        if keyframe {
            // 色空間・clamping_type（どちらも読み飛ばす）
            _ = header.literal(2)
            resetForKeyframe()
        }
        readSegmentation(&header)
        readLoopFilter(&header)
        var partitions: [VP8BoolDecoder] = try readPartitions(&header, bytes, start: offset + firstSize)
        readQuantizer(&header)
        let refresh: VP8RefreshFlags = readReferences(&header)
        if keyframe {
            entropy.coeffProbs = VP8Tables.defaultCoeffProbs
            entropy.mvProbs = VP8Tables.defaultMVProbs
            entropy.yModeProbs = VP8Tables.defaultYModeProbs
            entropy.uvModeProbs = VP8Tables.defaultUVModeProbs
        }
        saved = refresh.entropy ? nil : entropy
        readEntropy(&header)

        let current: VP8Picture = freePicture()
        references[VP8Decoder.currentFrame] = current
        let factors: [VP8Dequant] = dequantFactors()
        for i in 0..<aboveContext.count {
            aboveContext[i] = 0
        }
        for row in 0..<mbRows {
            var left: [UInt8] = Array(repeating: 0, count: 9)
            let tokenIndex: Int = row & (partitions.count - 1)
            for col in 0..<mbCols {
                decodeModes(&header, row: row, col: col)
                let at: Int = index(row, col)
                let segment: Int = info[at].segment
                decodeTokens(&partitions[tokenIndex], left: &left, col: col, at: at, factors: factors[segmentationEnabled ? segment : 0])
                reconstruct(current, row: row, col: col, at: at)
            }
            // 右端の上の 4 画素（次の行の B_PRED が使う）
            let y: UnsafeMutablePointer<UInt8> = current.y + (row * 16 + 15) * current.yStride + mbCols * 16
            let edge: UInt8 = y[-1]
            for i in 0..<4 {
                y[i] = edge
            }
        }
        if filterLevel > 0 {
            for row in 0..<mbRows {
                if filterSimple {
                    filterRowSimple(current, row: row)
                } else {
                    filterRowNormal(current, row: row)
                }
            }
        }
        if let restore = saved {
            entropy = restore
            saved = nil
        }
        updateReferences(refresh, current: current)
        if !shown { return nil }
        let image: Image = current.image(width: width, height: height)
        lastShown = image
        return image
    }

    private func allocate(width w: Int, height h: Int) {
        width = w
        height = h
        mbCols = (w + 15) / 16
        mbRows = (h + 15) / 16
        let count: Int = (mbCols + 1) * (mbRows + 1)
        info = Array(repeating: VP8MacroblockInfo(), count: count)
        subModes = Array(repeating: 0, count: count * 16)
        subMVs = Array(repeating: VP8MV(), count: count * 16)
        aboveContext = Array(repeating: 0, count: mbCols * 9)
        references = [nil, nil, nil, nil]
        pool = []
        lastShown = nil
    }

    private func resetForKeyframe() {
        segmentationEnabled = false
        segmentUpdateMap = false
        segmentAbsolute = false
        segmentTreeProbs = [255, 255, 255]
        segmentQuant = [0, 0, 0, 0]
        segmentFilter = [0, 0, 0, 0]
        filterSimple = false
        filterLevel = 0
        sharpness = 0
        filterDeltas = false
        refDelta = [0, 0, 0, 0]
        modeDelta = [0, 0, 0, 0]
    }

    /// 参照に使われていない絵（なければ新しく作る）。
    private func freePicture() -> VP8Picture {
        for picture in pool {
            let used: Bool = references[1...].contains { $0 === picture }
            if !used { return picture }
        }
        let made = VP8Picture(columns: mbCols, rows: mbRows)
        pool.append(made)
        return made
    }

    private func updateReferences(_ refresh: VP8RefreshFlags, current: VP8Picture) {
        if refresh.copyAltref == 1 {
            references[VP8Decoder.altrefFrame] = references[VP8Decoder.lastFrame]
        } else if refresh.copyAltref == 2 {
            references[VP8Decoder.altrefFrame] = references[VP8Decoder.goldenFrame]
        }
        if refresh.copyGolden == 1 {
            references[VP8Decoder.goldenFrame] = references[VP8Decoder.lastFrame]
        } else if refresh.copyGolden == 2 {
            references[VP8Decoder.goldenFrame] = references[VP8Decoder.altrefFrame]
        }
        if refresh.golden { references[VP8Decoder.goldenFrame] = current }
        if refresh.altref { references[VP8Decoder.altrefFrame] = current }
        if refresh.last { references[VP8Decoder.lastFrame] = current }
    }

    // MARK: 見出し（dixie.c）

    private func readSegmentation(_ bd: inout VP8BoolDecoder) {
        segmentationEnabled = bd.bit() == 1
        if segmentationEnabled {
            segmentUpdateMap = bd.bit() == 1
            let updateData: Bool = bd.bit() == 1
            if updateData {
                segmentAbsolute = bd.bit() == 1
                for i in 0..<4 {
                    segmentQuant[i] = bd.maybeSigned(7)
                }
                for i in 0..<4 {
                    segmentFilter[i] = bd.maybeSigned(6)
                }
            }
            if segmentUpdateMap {
                for i in 0..<3 {
                    segmentTreeProbs[i] = bd.bit() == 1 ? bd.literal(8) : 255
                }
            }
        } else {
            segmentUpdateMap = false
        }
    }

    private func readLoopFilter(_ bd: inout VP8BoolDecoder) {
        filterSimple = bd.bit() == 1
        filterLevel = bd.literal(6)
        sharpness = bd.literal(3)
        filterDeltas = bd.bit() == 1
        if filterDeltas && bd.bit() == 1 {
            for i in 0..<4 {
                refDelta[i] = bd.maybeSigned(6)
            }
            for i in 0..<4 {
                modeDelta[i] = bd.maybeSigned(6)
            }
        }
    }

    private func readPartitions(_ bd: inout VP8BoolDecoder, _ bytes: [UInt8], start: Int) throws -> [VP8BoolDecoder] {
        let count: Int = 1 << bd.literal(2)
        var position: Int = start
        let sizesLength: Int = 3 * (count - 1)
        guard position + sizesLength <= bytes.count else { throw DecodeError.invalid("VP8 の区切りの長さが途中で切れています") }
        var data: Int = position + sizesLength
        var remaining: Int = bytes.count - data
        var result: [VP8BoolDecoder] = []
        for i in 0..<count {
            var size: Int = remaining
            if i < count - 1 {
                let s0: Int = Int(bytes[position])
                let s1: Int = Int(bytes[position + 1])
                let s2: Int = Int(bytes[position + 2])
                size = s0 | (s1 << 8) | (s2 << 16)
                position += 3
            }
            guard size <= remaining else { throw DecodeError.invalid("VP8 の区切り \(i) が途中で切れています") }
            result.append(VP8BoolDecoder(bytes, start: data, size: size))
            data += size
            remaining -= size
        }
        return result
    }

    private func readQuantizer(_ bd: inout VP8BoolDecoder) {
        qIndex = bd.literal(7)
        y1DC = bd.maybeSigned(4)
        y2DC = bd.maybeSigned(4)
        y2AC = bd.maybeSigned(4)
        uvDC = bd.maybeSigned(4)
        uvAC = bd.maybeSigned(4)
    }

    private func readReferences(_ bd: inout VP8BoolDecoder) -> VP8RefreshFlags {
        var flags = VP8RefreshFlags()
        if keyframe {
            flags.golden = true
            flags.altref = true
            flags.last = true
            signBias = [false, false, false, false]
            flags.entropy = bd.bit() == 1
            return flags
        }
        flags.golden = bd.bit() == 1
        flags.altref = bd.bit() == 1
        flags.copyGolden = flags.golden ? 0 : bd.literal(2)
        flags.copyAltref = flags.altref ? 0 : bd.literal(2)
        signBias[VP8Decoder.goldenFrame] = bd.bit() == 1
        signBias[VP8Decoder.altrefFrame] = bd.bit() == 1
        flags.entropy = bd.bit() == 1
        flags.last = bd.bit() == 1
        return flags
    }

    private func readEntropy(_ bd: inout VP8BoolDecoder) {
        for i in 0..<(4 * 8 * 3 * 11) where bd.read(Int(VP8Tables.coeffUpdateProbs[i])) == 1 {
            entropy.coeffProbs[i] = UInt8(bd.literal(8))
        }
        entropy.skipEnabled = bd.bit() == 1
        entropy.skipProb = entropy.skipEnabled ? bd.literal(8) : 0
        if !keyframe {
            entropy.probInter = bd.literal(8)
            entropy.probLast = bd.literal(8)
            entropy.probGolden = bd.literal(8)
            if bd.bit() == 1 {
                for i in 0..<4 {
                    entropy.yModeProbs[i] = UInt8(bd.literal(8))
                }
            }
            if bd.bit() == 1 {
                for i in 0..<3 {
                    entropy.uvModeProbs[i] = UInt8(bd.literal(8))
                }
            }
            for i in 0..<(2 * 19) where bd.read(Int(VP8Tables.mvUpdateProbs[i])) == 1 {
                let x: Int = bd.literal(7)
                entropy.mvProbs[i] = x != 0 ? UInt8(x << 1) : 1
            }
        }
    }

    private func dequantFactors() -> [VP8Dequant] {
        var result: [VP8Dequant] = []
        let count: Int = segmentationEnabled ? 4 : 1
        for i in 0..<count {
            var q: Int = qIndex
            if segmentationEnabled {
                q = segmentAbsolute ? segmentQuant[i] : q + segmentQuant[i]
            }
            var factor = VP8Dequant()
            factor.y1 = (VP8Decoder.dcQ(q + y1DC), VP8Decoder.acQ(q))
            var uvDCValue: Int = VP8Decoder.dcQ(q + uvDC)
            if uvDCValue > 132 { uvDCValue = 132 }
            factor.uv = (uvDCValue, VP8Decoder.acQ(q + uvAC))
            var y2ACValue: Int = VP8Decoder.acQ(q + y2AC) * 155 / 100
            if y2ACValue < 8 { y2ACValue = 8 }
            factor.y2 = (VP8Decoder.dcQ(q + y2DC) * 2, y2ACValue)
            result.append(factor)
        }
        return result
    }

    private static func dcQ(_ q: Int) -> Int {
        return VP8Tables.dcQuant[max(0, min(127, q))]
    }

    private static func acQ(_ q: Int) -> Int {
        return VP8Tables.acQuant[max(0, min(127, q))]
    }

    // MARK: モードと動きベクトル（modemv.c）

    private func decodeModes(_ bd: inout VP8BoolDecoder, row: Int, col: Int) {
        let at: Int = index(row, col)
        if segmentUpdateMap {
            info[at].segment = bd.read(segmentTreeProbs[0]) == 1 ? 2 + bd.read(segmentTreeProbs[2]) : bd.read(segmentTreeProbs[1])
        } else if keyframe {
            info[at].segment = 0
        }
        info[at].skip = entropy.skipEnabled ? bd.read(entropy.skipProb) == 1 : false
        if keyframe {
            decodeKeyframeModes(&bd, at: at, left: at - 1, above: at - (mbCols + 1))
        } else if bd.read(entropy.probInter) == 1 {
            decodeMotion(&bd, row: row, col: col, at: at)
        } else {
            decodeIntraModes(&bd, at: at)
        }
    }

    private func blockMode(_ mb: Int, _ b: Int) -> Int {
        switch info[mb].yMode {
        case VP8Decoder.dcPred: return 0
        case VP8Decoder.vPred: return 2
        case VP8Decoder.hPred: return 3
        case VP8Decoder.tmPred: return 1
        default: return Int(subModes[mb * 16 + b])
        }
    }

    private func decodeKeyframeModes(_ bd: inout VP8BoolDecoder, at: Int, left: Int, above: Int) {
        let yMode: Int = bd.tree(VP8Tables.keyYModeTree, VP8Tables.keyYModeProbs)
        if yMode == VP8Decoder.bPred {
            for i in 0..<16 {
                let a: Int = i < 4 ? blockMode(above, i + 12) : Int(subModes[at * 16 + i - 4])
                let l: Int = i & 3 == 0 ? blockMode(left, i + 3) : Int(subModes[at * 16 + i - 1])
                let mode: Int = bd.tree(VP8Tables.bModeTree, VP8Tables.keyBModeProbs, (a * 10 + l) * 9)
                subModes[at * 16 + i] = UInt8(mode)
            }
        }
        info[at].yMode = yMode
        info[at].uvMode = bd.tree(VP8Tables.uvModeTree, VP8Tables.keyUVModeProbs)
        info[at].mv = VP8MV()
        info[at].refFrame = VP8Decoder.currentFrame
    }

    private func decodeIntraModes(_ bd: inout VP8BoolDecoder, at: Int) {
        let yMode: Int = bd.tree(VP8Tables.yModeTree, entropy.yModeProbs)
        if yMode == VP8Decoder.bPred {
            for i in 0..<16 {
                subModes[at * 16 + i] = UInt8(bd.tree(VP8Tables.bModeTree, VP8Tables.defaultBModeProbs))
            }
        }
        info[at].yMode = yMode
        info[at].uvMode = bd.tree(VP8Tables.uvModeTree, entropy.uvModeProbs)
        info[at].mv = VP8MV()
        info[at].refFrame = VP8Decoder.currentFrame
    }

    private func readMVComponent(_ bd: inout VP8BoolDecoder, _ base: Int) -> Int {
        let probs: [UInt8] = entropy.mvProbs
        var x: Int = 0
        if bd.read(Int(probs[base])) == 1 {
            for i in 0..<3 {
                x += bd.read(Int(probs[base + 9 + i])) << i
            }
            var i: Int = 9
            while i > 3 {
                x += bd.read(Int(probs[base + 9 + i])) << i
                i -= 1
            }
            if x & 0xFFF0 == 0 || bd.read(Int(probs[base + 9 + 3])) == 1 {
                x += 8
            }
        } else {
            x = bd.tree(VP8Tables.smallMVTree, probs, base + 2)
        }
        if x != 0 && bd.read(Int(probs[base + 1])) == 1 {
            x = -x
        }
        return x << 1
    }

    private func readMV(_ bd: inout VP8BoolDecoder) -> VP8MV {
        let y: Int = readMVComponent(&bd, 0)
        let x: Int = readMVComponent(&bd, 19)
        return VP8MV(x: Int16(truncatingIfNeeded: x), y: Int16(truncatingIfNeeded: y))
    }

    private func biased(_ mv: VP8MV, from mb: Int, to reference: Int) -> VP8MV {
        if signBias[info[mb].refFrame] != signBias[reference] {
            return VP8MV(x: 0 &- mv.x, y: 0 &- mv.y)
        }
        return mv
    }

    /// 近くの動きベクトル（find_near_mvs）。戻り値は [best, nearest, near] と数。
    private func nearMVs(at: Int, left: Int, above: Int, reference: Int) -> (mvs: [VP8MV], counts: [Int]) {
        let aboveLeft: Int = above - 1
        var mvs: [VP8MV] = [VP8MV(), VP8MV(), VP8MV(), VP8MV()]
        var counts: [Int] = [0, 0, 0, 0]
        var slot: Int = 0
        if info[above].refFrame != VP8Decoder.currentFrame {
            if !info[above].mv.isZero {
                slot += 1
                mvs[slot] = biased(info[above].mv, from: above, to: reference)
            }
            counts[slot] += 2
        }
        if info[left].refFrame != VP8Decoder.currentFrame {
            if !info[left].mv.isZero {
                let mv: VP8MV = biased(info[left].mv, from: left, to: reference)
                if mv != mvs[slot] {
                    slot += 1
                    mvs[slot] = mv
                }
                counts[slot] += 2
            } else {
                counts[0] += 2
            }
        }
        if info[aboveLeft].refFrame != VP8Decoder.currentFrame {
            if !info[aboveLeft].mv.isZero {
                let mv: VP8MV = biased(info[aboveLeft].mv, from: aboveLeft, to: reference)
                if mv != mvs[slot] {
                    slot += 1
                    mvs[slot] = mv
                }
                counts[slot] += 1
            } else {
                counts[0] += 1
            }
        }
        if counts[3] != 0 && mvs[slot] == mvs[1] {
            counts[1] += 1
        }
        let splitAbove: Int = info[above].yMode == VP8Decoder.splitMV ? 1 : 0
        let splitLeft: Int = info[left].yMode == VP8Decoder.splitMV ? 1 : 0
        let splitAboveLeft: Int = info[aboveLeft].yMode == VP8Decoder.splitMV ? 1 : 0
        counts[3] = (splitAbove + splitLeft) * 2 + splitAboveLeft
        if counts[2] > counts[1] {
            counts.swapAt(1, 2)
            mvs.swapAt(1, 2)
        }
        if counts[1] >= counts[0] {
            mvs[0] = mvs[1]
        }
        return (mvs, counts)
    }

    private func clamp(_ mv: VP8MV, row: Int, col: Int) -> VP8MV {
        let toLeft: Int = -((col + 1) << 7)
        let toRight: Int = (mbCols - col) << 7
        let toTop: Int = -((row + 1) << 7)
        let toBottom: Int = (mbRows - row) << 7
        let x: Int = max(toLeft, min(toRight, Int(mv.x)))
        let y: Int = max(toTop, min(toBottom, Int(mv.y)))
        return VP8MV(x: Int16(truncatingIfNeeded: x), y: Int16(truncatingIfNeeded: y))
    }

    private func decodeMotion(_ bd: inout VP8BoolDecoder, row: Int, col: Int, at: Int) {
        let reference: Int = bd.read(entropy.probLast) == 1 ? 2 + bd.read(entropy.probGolden) : 1
        info[at].refFrame = reference
        let left: Int = at - 1
        let above: Int = at - (mbCols + 1)
        let near: (mvs: [VP8MV], counts: [Int]) = nearMVs(at: at, left: left, above: above, reference: reference)
        var probs: [UInt8] = [0, 0, 0, 0]
        for i in 0..<4 {
            probs[i] = VP8Tables.mvCountsToProbs[near.counts[i] * 4 + i]
        }
        let mode: Int = bd.tree(VP8Tables.mvRefTree, probs)
        info[at].yMode = mode
        info[at].uvMode = mode
        switch mode {
        case VP8Decoder.nearestMV:
            info[at].mv = clamp(near.mvs[1], row: row, col: col)
        case VP8Decoder.nearMV:
            info[at].mv = clamp(near.mvs[2], row: row, col: col)
        case VP8Decoder.zeroMV:
            info[at].mv = VP8MV()
        case VP8Decoder.newMV:
            let best: VP8MV = clamp(near.mvs[0], row: row, col: col)
            let delta: VP8MV = readMV(&bd)
            info[at].mv = VP8MV(x: delta.x &+ best.x, y: delta.y &+ best.y)
        default:
            let best: VP8MV = clamp(near.mvs[0], row: row, col: col)
            decodeSplit(&bd, at: at, left: left, above: above, best: best)
            info[at].mv = subMVs[at * 16 + 15]
        }
    }

    private func blockMV(_ mb: Int, _ b: Int) -> VP8MV {
        if info[mb].yMode == VP8Decoder.splitMV { return subMVs[mb * 16 + b] }
        return info[mb].mv
    }

    private func decodeSplit(_ bd: inout VP8BoolDecoder, at: Int, left: Int, above: Int, best: VP8MV) {
        let partitionID: Int = bd.tree(VP8Tables.splitMVTree, VP8Tables.splitMVProbs)
        info[at].partitioning = partitionID
        let base: Int = partitionID * 16
        var mask: Int = 0
        var j: Int = 0
        while mask < 65535 {
            var k: Int = 0
            while j != VP8Tables.mvPartitions[base + k] {
                k += 1
            }
            let leftMV: VP8MV = k & 3 == 0 ? blockMV(left, k + 3) : subMVs[at * 16 + k - 1]
            let aboveMV: VP8MV = k < 4 ? blockMV(above, k + 12) : subMVs[at * 16 + k - 4]
            let leftZero: Bool = leftMV.isZero
            let aboveZero: Bool = aboveMV.isZero
            let same: Bool = leftMV == aboveMV
            var context: Int = 0
            if same && leftZero {
                context = 4
            } else if same {
                context = 3
            } else if aboveZero {
                context = 2
            } else if leftZero {
                context = 1
            }
            let subMode: Int = bd.tree(VP8Tables.subMVRefTree, VP8Tables.subMVRefProbs, context * 3)
            var mv: VP8MV
            switch subMode {
            case VP8Decoder.left4x4:
                mv = leftMV
            case VP8Decoder.above4x4:
                mv = aboveMV
            case VP8Decoder.zero4x4:
                mv = VP8MV()
            default:
                let delta: VP8MV = readMV(&bd)
                mv = VP8MV(x: delta.x &+ best.x, y: delta.y &+ best.y)
            }
            while k < 16 {
                if j == VP8Tables.mvPartitions[base + k] {
                    subMVs[at * 16 + k] = mv
                    mask |= 1 << k
                }
                k += 1
            }
            j += 1
        }
    }

    // MARK: 係数（tokens.c）

    private static let zigzag: [Int] = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15]
    private static let bands: [Int] = [0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7]
    private static let leftIndex: [Int] = [0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8]
    private static let aboveIndex: [Int] = [0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3, 4, 5, 4, 5, 6, 7, 6, 7, 8]
    private static let cat3: [Int] = [173, 148, 140]
    private static let cat4: [Int] = [176, 155, 140, 135]
    private static let cat5: [Int] = [180, 157, 141, 134, 130]
    private static let cat6: [Int] = [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129]

    private func decodeTokens(_ bd: inout VP8BoolDecoder, left: inout [UInt8], col: Int, at: Int, factors: VP8Dequant) {
        for i in 0..<coefficients.count {
            coefficients[i] = 0
        }
        let mode: Int = info[at].yMode
        let hasY2: Bool = mode != VP8Decoder.bPred && mode != VP8Decoder.splitMV
        let aboveBase: Int = col * 9
        if info[at].skip {
            for i in 0..<8 {
                left[i] = 0
                aboveContext[aboveBase + i] = 0
            }
            if hasY2 {
                left[8] = 0
                aboveContext[aboveBase + 8] = 0
            }
            info[at].coded = false
            return
        }
        var coded: Bool = false
        if hasY2 {
            coded = decodeBlock(&bd, block: 24, type: 1, factor: factors.y2, left: &left, aboveBase: aboveBase) || coded
            for b in 0..<16 {
                coded = decodeBlock(&bd, block: b, type: 0, factor: factors.y1, left: &left, aboveBase: aboveBase) || coded
            }
        } else {
            for b in 0..<16 {
                coded = decodeBlock(&bd, block: b, type: 3, factor: factors.y1, left: &left, aboveBase: aboveBase) || coded
            }
        }
        for b in 16..<24 {
            coded = decodeBlock(&bd, block: b, type: 2, factor: factors.uv, left: &left, aboveBase: aboveBase) || coded
        }
        info[at].coded = coded
    }

    /// 1 つのブロックの係数（decode_mb_tokens の 1 ブロック分）。何か読んだら true。
    private func decodeBlock(_ bd: inout VP8BoolDecoder, block: Int, type: Int, factor: (dc: Int, ac: Int),
                             left: inout [UInt8], aboveBase: Int) -> Bool {
        let l: Int = VP8Decoder.leftIndex[block]
        let a: Int = aboveBase + VP8Decoder.aboveIndex[block]
        let start: Int = type == 0 ? 1 : 0
        var c: Int = start
        var context: Int = Int(left[l]) + Int(aboveContext[a])
        let typeBase: Int = type * 264
        var skipEOB: Bool = false
        let probs: [UInt8] = entropy.coeffProbs
        while c < 16 {
            let p: Int = typeBase + VP8Decoder.bands[c] * 33 + context * 11
            if !skipEOB && bd.read(Int(probs[p])) == 0 { break }
            if bd.read(Int(probs[p + 1])) == 0 {
                context = 0
                skipEOB = true
                c += 1
                continue
            }
            skipEOB = false
            var value: Int
            if bd.read(Int(probs[p + 2])) == 0 {
                value = 1
                context = 1
            } else {
                context = 2
                value = VP8Decoder.largeToken(&bd, probs, p)
            }
            if bd.bit() == 1 { value = -value }
            let q: Int = c > 0 ? factor.ac : factor.dc
            coefficients[block * 16 + VP8Decoder.zigzag[c]] = Int16(truncatingIfNeeded: value * q)
            c += 1
        }
        let coded: Bool = c != start
        let flag: UInt8 = coded ? 1 : 0
        left[l] = flag
        aboveContext[a] = flag
        return coded
    }

    /// 2 以上の値（LOW_VAL の節から下）。
    private static func largeToken(_ bd: inout VP8BoolDecoder, _ probs: [UInt8], _ p: Int) -> Int {
        if bd.read(Int(probs[p + 3])) == 0 {
            if bd.read(Int(probs[p + 4])) == 0 { return 2 }
            return bd.read(Int(probs[p + 5])) == 0 ? 3 : 4
        }
        if bd.read(Int(probs[p + 6])) == 0 {
            if bd.read(Int(probs[p + 7])) == 0 {
                return 5 + bd.read(159)
            }
            var value: Int = 7
            value += bd.read(165) << 1
            value += bd.read(145)
            return value
        }
        if bd.read(Int(probs[p + 8])) == 0 {
            if bd.read(Int(probs[p + 9])) == 0 {
                return 11 + VP8Decoder.extraBits(&bd, cat3)
            }
            return 19 + VP8Decoder.extraBits(&bd, cat4)
        }
        if bd.read(Int(probs[p + 10])) == 0 {
            return 35 + VP8Decoder.extraBits(&bd, cat5)
        }
        return 67 + VP8Decoder.extraBits(&bd, cat6)
    }

    /// 上位のビットから順に読む（probs[0] が一番上のビット）。
    private static func extraBits(_ bd: inout VP8BoolDecoder, _ probs: [Int]) -> Int {
        var value: Int = 0
        for p in probs {
            value = (value << 1) | bd.read(p)
        }
        return value
    }

    // MARK: 予測と足し合わせ（predict.c・idct_add.c）

    private func reconstruct(_ picture: VP8Picture, row: Int, col: Int, at: Int) {
        let mode: Int = info[at].yMode
        let uvMode: Int = info[at].uvMode
        let y: UnsafeMutablePointer<UInt8> = picture.y + row * 16 * picture.yStride + col * 16
        let u: UnsafeMutablePointer<UInt8> = picture.u + row * 8 * picture.uvStride + col * 8
        let v: UnsafeMutablePointer<UInt8> = picture.v + row * 8 * picture.uvStride + col * 8
        if col == 0 {
            VP8Predict.fixupLeft(y, 16, picture.yStride, row, mode)
            VP8Predict.fixupLeft(u, 8, picture.uvStride, row, uvMode)
            VP8Predict.fixupLeft(v, 8, picture.uvStride, row, uvMode)
            if row == 0 { y[-picture.yStride - 1] = 127 }
        }
        if row == 0 {
            VP8Predict.fixupAbove(y, 16, picture.yStride, col, mode)
            VP8Predict.fixupAbove(u, 8, picture.uvStride, col, uvMode)
            VP8Predict.fixupAbove(v, 8, picture.uvStride, col, uvMode)
        }
        coefficients.withUnsafeMutableBufferPointer { (buffer: inout UnsafeMutableBufferPointer<Int16>) in
            guard let coeffs = buffer.baseAddress else { return }
            if mode <= VP8Decoder.bPred {
                if mode == VP8Decoder.bPred {
                    subModes.withUnsafeBufferPointer { (modes: UnsafeBufferPointer<UInt8>) in
                        VP8Predict.bPred(y, picture.yStride, modes, at * 16, coeffs)
                    }
                } else {
                    VP8Predict.lumaIntra(y, picture.yStride, mode)
                    VP8Predict.walshIntoDC(coeffs)
                    VP8Predict.addLuma(y, picture.yStride, coeffs)
                }
                VP8Predict.chromaIntra(u, picture.uvStride, uvMode)
                VP8Predict.chromaIntra(v, picture.uvStride, uvMode)
                VP8Predict.addChroma(u, v, picture.uvStride, coeffs)
            } else {
                if mode != VP8Decoder.splitMV {
                    VP8Predict.walshIntoDC(coeffs)
                }
                predictInter(picture, row: row, col: col, at: at, coeffs: coeffs)
            }
        }
    }

    private func predictInter(_ picture: VP8Picture, row: Int, col: Int, at: Int, coeffs: UnsafeMutablePointer<Int16>) {
        guard let reference = references[info[at].refFrame] else { return }
        let fullPixel: Bool = version == 3
        let filters: [Int] = version == 0 ? VP8Predict.sixtap : VP8Predict.bilinear
        let split: Bool = info[at].yMode == VP8Decoder.splitMV
        var chroma: [VP8MV] = []
        if !split {
            let mv: VP8MV = info[at].mv
            var cx: Int = Int(mv.x)
            var cy: Int = Int(mv.y)
            cx = (cx + 1 + (cx < 0 ? -2 : 0)) / 2
            cy = (cy + 1 + (cy < 0 ? -2 : 0)) / 2
            if fullPixel {
                cx &= ~7
                cy &= ~7
            }
            let c: VP8MV = VP8MV(x: Int16(truncatingIfNeeded: cx), y: Int16(truncatingIfNeeded: cy))
            chroma = [c, c, c, c]
        } else {
            for b in [0, 2, 8, 10] {
                chroma.append(chromaSplitMV(at, b, fullPixel))
            }
        }
        let lumaW: Int = mbCols * 16
        let lumaH: Int = mbRows * 16
        for b in 0..<16 {
            let mv: VP8MV = split ? subMVs[at * 16 + b] : info[at].mv
            let bx: Int = col * 16 + (b & 3) * 4
            let by: Int = row * 16 + (b >> 2) * 4
            VP8Predict.interBlock(picture.y, reference.y, picture.yStride, bx, by, lumaW, lumaH, mv, filters, coeffs + b * 16)
        }
        let chromaW: Int = mbCols * 8
        let chromaH: Int = mbRows * 8
        for b in 0..<4 {
            let bx: Int = col * 8 + (b & 1) * 4
            let by: Int = row * 8 + (b >> 1) * 4
            VP8Predict.interBlock(picture.u, reference.u, picture.uvStride, bx, by, chromaW, chromaH, chroma[b], filters, coeffs + (16 + b) * 16)
            VP8Predict.interBlock(picture.v, reference.v, picture.uvStride, bx, by, chromaW, chromaH, chroma[b], filters, coeffs + (20 + b) * 16)
        }
    }

    private func chromaSplitMV(_ at: Int, _ b: Int, _ fullPixel: Bool) -> VP8MV {
        let base: Int = at * 16
        let indices: [Int] = [b, b + 1, b + 4, b + 5]
        var sumX: Int = 0
        var sumY: Int = 0
        for i in indices {
            sumX += Int(subMVs[base + i].x)
            sumY += Int(subMVs[base + i].y)
        }
        sumX += sumX < 0 ? -4 : 4
        sumY += sumY < 0 ? -4 : 4
        var x: Int = sumX / 8
        var y: Int = sumY / 8
        if fullPixel {
            x &= ~7
            y &= ~7
        }
        return VP8MV(x: Int16(truncatingIfNeeded: x), y: Int16(truncatingIfNeeded: y))
    }

    // MARK: ループフィルター（dixie_loopfilter.c）

    private func filterParameters(_ at: Int) -> (edge: Int, interior: Int, hev: Int) {
        var level: Int = filterLevel
        if segmentationEnabled {
            let segment: Int = info[at].segment
            level = segmentAbsolute ? segmentFilter[segment] : level + segmentFilter[segment]
        }
        level = max(0, min(63, level))
        if filterDeltas {
            let reference: Int = info[at].refFrame
            let mode: Int = info[at].yMode
            level += refDelta[reference]
            if reference == VP8Decoder.currentFrame {
                if mode == VP8Decoder.bPred { level += modeDelta[0] }
            } else if mode == VP8Decoder.zeroMV {
                level += modeDelta[1]
            } else if mode == VP8Decoder.splitMV {
                level += modeDelta[3]
            } else {
                level += modeDelta[2]
            }
        }
        level = max(0, min(63, level))
        var interior: Int = level
        if sharpness > 0 {
            interior >>= sharpness > 4 ? 2 : 1
            if interior > 9 - sharpness { interior = 9 - sharpness }
        }
        if interior < 1 { interior = 1 }
        var hev: Int = level >= 15 ? 1 : 0
        if level >= 40 { hev += 1 }
        if level >= 20 && !keyframe { hev += 1 }
        return (level, interior, hev)
    }

    private func filterRowNormal(_ picture: VP8Picture, row: Int) {
        let stride: Int = picture.yStride
        let uvStride: Int = picture.uvStride
        for col in 0..<mbCols {
            let at: Int = index(row, col)
            let p: (edge: Int, interior: Int, hev: Int) = filterParameters(at)
            if p.edge == 0 { continue }
            let y: UnsafeMutablePointer<UInt8> = picture.y + row * 16 * stride + col * 16
            let u: UnsafeMutablePointer<UInt8> = picture.u + row * 8 * uvStride + col * 8
            let v: UnsafeMutablePointer<UInt8> = picture.v + row * 8 * uvStride + col * 8
            let mode: Int = info[at].yMode
            let inner: Bool = info[at].coded || mode == VP8Decoder.splitMV || mode == VP8Decoder.bPred
            let mbEdge: Int = p.edge + 2
            if col > 0 {
                VP8LoopFilter.mbEdge(y, 1, stride, mbEdge, p.interior, p.hev, 16)
                VP8LoopFilter.mbEdge(u, 1, uvStride, mbEdge, p.interior, p.hev, 8)
                VP8LoopFilter.mbEdge(v, 1, uvStride, mbEdge, p.interior, p.hev, 8)
            }
            if inner {
                for x in [4, 8, 12] {
                    VP8LoopFilter.subblockEdge(y + x, 1, stride, p.edge, p.interior, p.hev, 16)
                }
                VP8LoopFilter.subblockEdge(u + 4, 1, uvStride, p.edge, p.interior, p.hev, 8)
                VP8LoopFilter.subblockEdge(v + 4, 1, uvStride, p.edge, p.interior, p.hev, 8)
            }
            if row > 0 {
                VP8LoopFilter.mbEdge(y, stride, 1, mbEdge, p.interior, p.hev, 16)
                VP8LoopFilter.mbEdge(u, uvStride, 1, mbEdge, p.interior, p.hev, 8)
                VP8LoopFilter.mbEdge(v, uvStride, 1, mbEdge, p.interior, p.hev, 8)
            }
            if inner {
                for line in [4, 8, 12] {
                    VP8LoopFilter.subblockEdge(y + line * stride, stride, 1, p.edge, p.interior, p.hev, 16)
                }
                VP8LoopFilter.subblockEdge(u + 4 * uvStride, uvStride, 1, p.edge, p.interior, p.hev, 8)
                VP8LoopFilter.subblockEdge(v + 4 * uvStride, uvStride, 1, p.edge, p.interior, p.hev, 8)
            }
        }
    }

    private func filterRowSimple(_ picture: VP8Picture, row: Int) {
        let stride: Int = picture.yStride
        for col in 0..<mbCols {
            let at: Int = index(row, col)
            let p: (edge: Int, interior: Int, hev: Int) = filterParameters(at)
            if p.edge == 0 { continue }
            let y: UnsafeMutablePointer<UInt8> = picture.y + row * 16 * stride + col * 16
            let mode: Int = info[at].yMode
            let inner: Bool = info[at].coded || mode == VP8Decoder.splitMV || mode == VP8Decoder.bPred
            let mbLimit: Int = (p.edge + 2) * 2 + p.interior
            let bLimit: Int = p.edge * 2 + p.interior
            if col > 0 { VP8LoopFilter.simple(y, 1, stride, mbLimit) }
            if inner {
                for x in [4, 8, 12] {
                    VP8LoopFilter.simple(y + x, 1, stride, bLimit)
                }
            }
            if row > 0 { VP8LoopFilter.simple(y, stride, 1, mbLimit) }
            if inner {
                for line in [4, 8, 12] {
                    VP8LoopFilter.simple(y + line * stride, stride, 1, bLimit)
                }
            }
        }
    }
}

/// 動きベクトル（1/8 画素単位。輝度は偶数＝1/4 画素）。
struct VP8MV: Equatable {
    var x: Int16 = 0
    var y: Int16 = 0
    var isZero: Bool { return x == 0 && y == 0 }
}

struct VP8MacroblockInfo {
    var yMode: Int = 0
    var uvMode: Int = 0
    var segment: Int = 0
    var refFrame: Int = 0
    var skip: Bool = false
    var mv: VP8MV = VP8MV()
    var partitioning: Int = 0
    /// 係数を 1 つでも読んだか（ループフィルターが中の境目をかけるか決める）
    var coded: Bool = false
}

struct VP8Entropy {
    var coeffProbs: [UInt8] = VP8Tables.defaultCoeffProbs
    var mvProbs: [UInt8] = VP8Tables.defaultMVProbs
    var yModeProbs: [UInt8] = VP8Tables.defaultYModeProbs
    var uvModeProbs: [UInt8] = VP8Tables.defaultUVModeProbs
    var skipEnabled: Bool = false
    var skipProb: Int = 0
    var probInter: Int = 0
    var probLast: Int = 0
    var probGolden: Int = 0
}

struct VP8RefreshFlags {
    var golden: Bool = false
    var altref: Bool = false
    var last: Bool = false
    var copyGolden: Int = 0
    var copyAltref: Int = 0
    var entropy: Bool = true
}

struct VP8Dequant {
    var y1: (dc: Int, ac: Int) = (0, 0)
    var y2: (dc: Int, ac: Int) = (0, 0)
    var uv: (dc: Int, ac: Int) = (0, 0)
}

/// ブール符号の読み手（bool_decoder.h）。
struct VP8BoolDecoder {
    private let bytes: [UInt8]
    private var position: Int
    private let end: Int
    private var value: UInt32
    private var range: UInt32 = 255
    private var bitCount: Int = 0

    init(_ bytes: [UInt8], start: Int, size: Int) {
        self.bytes = bytes
        let limit: Int = min(bytes.count, start + max(0, size))
        end = limit
        if size >= 2 && start + 2 <= limit {
            let first: UInt32 = UInt32(bytes[start])
            let second: UInt32 = UInt32(bytes[start + 1])
            value = (first << 8) | second
            position = start + 2
        } else {
            value = 0
            position = limit
        }
    }

    mutating func read(_ probability: Int) -> Int {
        let p: UInt32 = UInt32(truncatingIfNeeded: probability)
        let split: UInt32 = 1 + (((range - 1) * p) >> 8)
        let bigSplit: UInt32 = split << 8
        var bit: Int = 0
        if value >= bigSplit {
            bit = 1
            range -= split
            value -= bigSplit
        } else {
            range = split
        }
        while range < 128 {
            value <<= 1
            range <<= 1
            bitCount += 1
            if bitCount == 8 {
                bitCount = 0
                if position < end {
                    value |= UInt32(bytes[position])
                    position += 1
                }
            }
        }
        return bit
    }

    mutating func bit() -> Int {
        return read(128)
    }

    mutating func literal(_ bits: Int) -> Int {
        var value: Int = 0
        var bit: Int = bits - 1
        while bit >= 0 {
            value |= read(128) << bit
            bit -= 1
        }
        return value
    }

    mutating func signed(_ bits: Int) -> Int {
        let magnitude: Int = literal(bits)
        return read(128) == 1 ? -magnitude : magnitude
    }

    mutating func maybeSigned(_ bits: Int) -> Int {
        return read(128) == 1 ? signed(bits) : 0
    }

    /// 木の形の符号（bool_read_tree）。probs は base から使う。
    mutating func tree(_ t: [Int], _ probs: [UInt8], _ base: Int = 0) -> Int {
        var i: Int = 0
        repeat {
            let probability: Int = Int(probs[base + (i >> 1)])
            i = t[i + read(probability)]
        } while i > 0
        return -i
    }
}

/// 1 フレーム分の絵（I420）。周りに縁があり、イントラ予測の端の値を書き込める。
final class VP8Picture {
    static let border: Int = 32
    static let chromaBorder: Int = 16
    let yStride: Int
    let uvStride: Int
    let columns: Int
    let rows: Int
    private let yStorage: UnsafeMutablePointer<UInt8>
    private let uStorage: UnsafeMutablePointer<UInt8>
    private let vStorage: UnsafeMutablePointer<UInt8>
    private let yCount: Int
    private let uvCount: Int
    /// 左上の画素
    let y: UnsafeMutablePointer<UInt8>
    let u: UnsafeMutablePointer<UInt8>
    let v: UnsafeMutablePointer<UInt8>

    init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        let b: Int = VP8Picture.border
        let cb: Int = VP8Picture.chromaBorder
        yStride = columns * 16 + 2 * b
        uvStride = columns * 8 + 2 * cb
        yCount = yStride * (rows * 16 + 2 * b)
        uvCount = uvStride * (rows * 8 + 2 * cb)
        yStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: yCount)
        uStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: uvCount)
        vStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: uvCount)
        yStorage.initialize(repeating: 0, count: yCount)
        uStorage.initialize(repeating: 0, count: uvCount)
        vStorage.initialize(repeating: 0, count: uvCount)
        y = yStorage + b * yStride + b
        u = uStorage + cb * uvStride + cb
        v = vStorage + cb * uvStride + cb
    }

    deinit {
        yStorage.deallocate()
        uStorage.deallocate()
        vStorage.deallocate()
    }

    /// 表示する大きさに切り出す。
    func image(width: Int, height: Int) -> VP8Decoder.Image {
        let cw: Int = (width + 1) / 2
        let ch: Int = (height + 1) / 2
        var yPlane: [UInt8] = Array(repeating: 0, count: width * height)
        var uPlane: [UInt8] = Array(repeating: 0, count: cw * ch)
        var vPlane: [UInt8] = Array(repeating: 0, count: cw * ch)
        for row in 0..<height {
            for x in 0..<width {
                yPlane[row * width + x] = y[row * yStride + x]
            }
        }
        for row in 0..<ch {
            for x in 0..<cw {
                uPlane[row * cw + x] = u[row * uvStride + x]
                vPlane[row * cw + x] = v[row * uvStride + x]
            }
        }
        return VP8Decoder.Image(width: width, height: height, y: yPlane, u: uPlane, v: vPlane)
    }
}
