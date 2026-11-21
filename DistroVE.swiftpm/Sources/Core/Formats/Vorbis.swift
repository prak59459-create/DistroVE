import Foundation

/// Vorbis I の解読（Q71: MKV・WebM・Ogg の音声）。iPad には Vorbis の解読器が無いため、仕様どおりに Swift で書く。
/// 仕様: Xiph.Org Foundation「Vorbis I specification」。
/// 符号帳（ハフマン木・VQ）、floor 1、residue 0/1/2、チャンネル結合、IMDCT（FFT で計算）、窓と重ね合わせ。
/// floor 0 は 2004 年以降の符号器が使わないため、読めないこととして扱う。
final class VorbisDecoder {
    enum DecodeError: Error, Equatable {
        case invalidHeader(String)
        case unsupported(String)
    }

    let channels: Int
    let sampleRate: Double
    let blocksize0: Int
    let blocksize1: Int

    private let codebooks: [VorbisCodebook]
    private let floors: [VorbisFloor1]
    private let residues: [VorbisResidue]
    private let mappings: [VorbisMapping]
    private let modes: [VorbisMode]
    private let modeBits: Int
    private let shortTransform: VorbisIMDCT
    private let longTransform: VorbisIMDCT
    /// 立ち上がりの窓（長さ blocksize/2）
    private let shortSlope: [Float]
    private let longSlope: [Float]

    /// 前のブロックの、真ん中から右の窓の終わりまで（チャンネルごと）
    private var tails: [[Float]] = []
    /// tails の先頭のうち、窓が 1 の（重ならない）部分の長さ
    private var tailFlat: Int = 0
    private var primed: Bool = false

    /// 3 つの見出し（識別・コメント・設定）から作る。
    init(headers: [Data]) throws {
        guard headers.count >= 3 else { throw DecodeError.invalidHeader("見出しが 3 つありません") }
        var id = VorbisBitReader(headers[0])
        guard id.read(8) == 1, VorbisDecoder.hasMagic(&id) else { throw DecodeError.invalidHeader("識別の見出しではありません") }
        guard id.read(32) == 0 else { throw DecodeError.unsupported("Vorbis の版が違います") }
        let channelCount: Int = id.read(8)
        let rate: Int = id.read(32)
        _ = id.read(32)
        _ = id.read(32)
        _ = id.read(32)
        let small: Int = 1 << id.read(4)
        let large: Int = 1 << id.read(4)
        let framing: Int = id.read(1)
        guard channelCount > 0, rate > 0, small >= 64, large <= 8192, small <= large, framing == 1, !id.endOfPacket else {
            throw DecodeError.invalidHeader("識別の見出しの値が正しくありません")
        }
        channels = channelCount
        sampleRate = Double(rate)
        blocksize0 = small
        blocksize1 = large

        var setup = VorbisBitReader(headers[2])
        guard setup.read(8) == 5, VorbisDecoder.hasMagic(&setup) else { throw DecodeError.invalidHeader("設定の見出しではありません") }
        var books: [VorbisCodebook] = []
        let bookCount: Int = setup.read(8) + 1
        for _ in 0..<bookCount {
            books.append(try VorbisCodebook(&setup))
        }
        let timeCount: Int = setup.read(6) + 1
        for _ in 0..<timeCount where setup.read(16) != 0 {
            throw DecodeError.invalidHeader("時間領域の変換が 0 ではありません")
        }
        var floorList: [VorbisFloor1] = []
        let floorCount: Int = setup.read(6) + 1
        for _ in 0..<floorCount {
            let type: Int = setup.read(16)
            if type == 0 { throw DecodeError.unsupported("floor 0 の Vorbis（2004 年より前の符号器）は読めません") }
            guard type == 1 else { throw DecodeError.invalidHeader("floor の種類が正しくありません") }
            floorList.append(try VorbisFloor1(&setup, books: books))
        }
        var residueList: [VorbisResidue] = []
        let residueCount: Int = setup.read(6) + 1
        for _ in 0..<residueCount {
            let type: Int = setup.read(16)
            guard type <= 2 else { throw DecodeError.invalidHeader("residue の種類が正しくありません") }
            residueList.append(try VorbisResidue(&setup, type: type, books: books))
        }
        var mappingList: [VorbisMapping] = []
        let mappingCount: Int = setup.read(6) + 1
        for _ in 0..<mappingCount {
            guard setup.read(16) == 0 else { throw DecodeError.invalidHeader("mapping の種類が正しくありません") }
            mappingList.append(try VorbisMapping(&setup, channels: channelCount, floors: floorList.count, residues: residueList.count))
        }
        var modeList: [VorbisMode] = []
        let modeCount: Int = setup.read(6) + 1
        for _ in 0..<modeCount {
            let blockflag: Bool = setup.read(1) == 1
            let window: Int = setup.read(16)
            let transform: Int = setup.read(16)
            let mapping: Int = setup.read(8)
            guard window == 0, transform == 0, mapping < mappingList.count else { throw DecodeError.invalidHeader("mode の値が正しくありません") }
            modeList.append(VorbisMode(long: blockflag, mapping: mapping))
        }
        guard setup.read(1) == 1, !setup.endOfPacket else { throw DecodeError.invalidHeader("設定の見出しが途中で終わっています") }
        codebooks = books
        floors = floorList
        residues = residueList
        mappings = mappingList
        modes = modeList
        modeBits = VorbisBits.ilog(modeList.count - 1)
        shortTransform = VorbisIMDCT(size: small)
        longTransform = VorbisIMDCT(size: large)
        shortSlope = VorbisDecoder.slope(small / 2)
        longSlope = VorbisDecoder.slope(large / 2)
    }

    /// Matroska の CodecPrivate（Xiph のまとめ方で 3 つの見出しを並べたもの）から作る。
    convenience init(codecPrivate: Data) throws {
        guard let headers = VorbisDecoder.xiphPackets(codecPrivate), headers.count == 3 else {
            throw DecodeError.invalidHeader("Vorbis の見出しが見つかりません")
        }
        try self.init(headers: headers)
    }

    /// Xiph のまとめ方：先頭 1 バイトが「数 - 1」、続いて最後以外の大きさ（255 が続く書き方）、そのあと中身。
    static func xiphPackets(_ data: Data) -> [Data]? {
        let bytes: [UInt8] = [UInt8](data)
        guard let first = bytes.first else { return nil }
        let count: Int = Int(first) + 1
        var offset: Int = 1
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var size: Int = 0
            while offset < bytes.count {
                let byte: Int = Int(bytes[offset])
                offset += 1
                size += byte
                if byte < 255 { break }
            }
            sizes.append(size)
        }
        var packets: [Data] = []
        for size in sizes {
            guard offset + size <= bytes.count else { return nil }
            packets.append(Data(bytes[offset..<(offset + size)]))
            offset += size
        }
        guard offset <= bytes.count else { return nil }
        packets.append(Data(bytes[offset...]))
        return packets
    }

    private static func hasMagic(_ reader: inout VorbisBitReader) -> Bool {
        let magic: [Int] = [0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]
        for value in magic where reader.read(8) != value {
            return false
        }
        return true
    }

    /// 窓の立ち上がり sin(π/2・sin²((i+0.5)/n・π/2))。
    static func slope(_ n: Int) -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(n)
        for i in 0..<n {
            let inner: Double = sin((Double(i) + 0.5) / Double(n) * Double.pi / 2)
            values.append(Float(sin(Double.pi / 2 * inner * inner)))
        }
        return values
    }

    /// 次のストリームの最初からやり直す（シークのあとなど）。
    func reset() {
        primed = false
        tails = []
        tailFlat = 0
    }

    /// 音声のパケットを 1 つ解読する。戻り値はチャンネルごとのサンプル（最初のパケットは空）。
    func decode(_ packet: Data) -> [[Float]] {
        var reader = VorbisBitReader(packet)
        if reader.read(1) != 0 { return [] }
        let modeNumber: Int = reader.read(modeBits)
        if reader.endOfPacket || modeNumber >= modes.count { return [] }
        let mode: VorbisMode = modes[modeNumber]
        let n: Int = mode.long ? blocksize1 : blocksize0
        var previousLong: Bool = true
        var nextLong: Bool = true
        if mode.long {
            previousLong = reader.read(1) == 1
            nextLong = reader.read(1) == 1
        }
        if reader.endOfPacket { return [] }
        let half: Int = n / 2
        let window: VorbisWindow = VorbisWindow(n: n, small: blocksize0, long: mode.long, previousLong: previousLong, nextLong: nextLong)
        let mapping: VorbisMapping = mappings[mode.mapping]

        // floor
        var floorValues: [[Int]?] = []
        var noResidue: [Bool] = []
        for channel in 0..<channels {
            let floor: VorbisFloor1 = floors[mapping.submapFloor[mapping.mux[channel]]]
            let values: [Int]? = floor.decode(&reader, books: codebooks)
            floorValues.append(values)
            noResidue.append(values == nil)
        }
        for step in 0..<mapping.magnitude.count {
            let m: Int = mapping.magnitude[step]
            let a: Int = mapping.angle[step]
            if !noResidue[m] || !noResidue[a] {
                noResidue[m] = false
                noResidue[a] = false
            }
        }

        // residue
        var spectra: [[Float]] = Array(repeating: Array(repeating: 0, count: half), count: channels)
        for submap in 0..<mapping.submapFloor.count {
            var bundle: [Int] = []
            for channel in 0..<channels where mapping.mux[channel] == submap {
                bundle.append(channel)
            }
            if bundle.isEmpty { continue }
            var vectors: [[Float]] = Array(repeating: Array(repeating: 0, count: half), count: bundle.count)
            let skip: [Bool] = bundle.map { noResidue[$0] }
            residues[mapping.submapResidue[submap]].decode(&vectors, skip: skip, n: half, books: codebooks, reader: &reader)
            for (index, channel) in bundle.enumerated() {
                spectra[channel] = vectors[index]
            }
        }

        // チャンネル結合を戻す
        for step in stride(from: mapping.magnitude.count - 1, through: 0, by: -1) {
            var magnitude: [Float] = spectra[mapping.magnitude[step]]
            var angle: [Float] = spectra[mapping.angle[step]]
            VorbisDecoder.uncouple(&magnitude, &angle)
            spectra[mapping.magnitude[step]] = magnitude
            spectra[mapping.angle[step]] = angle
        }

        // floor を掛けて、時間の信号に戻し、窓を掛ける
        let transform: VorbisIMDCT = mode.long ? longTransform : shortTransform
        var blocks: [[Float]] = []
        for channel in 0..<channels {
            var time: [Float] = Array(repeating: 0, count: n)
            if let values = floorValues[channel] {
                let floor: VorbisFloor1 = floors[mapping.submapFloor[mapping.mux[channel]]]
                let curve: [Float] = floor.curve(values, n: half)
                var spectrum: [Float] = spectra[channel]
                for i in 0..<half {
                    spectrum[i] *= curve[i]
                }
                transform.inverse(spectrum, into: &time)
                applyWindow(&time, window)
            }
            blocks.append(time)
        }
        return overlap(blocks, window: window, half: half)
    }

    private static func uncouple(_ magnitude: inout [Float], _ angle: inout [Float]) {
        let count: Int = min(magnitude.count, angle.count)
        for i in 0..<count {
            let m: Float = magnitude[i]
            let a: Float = angle[i]
            if m > 0 {
                if a > 0 {
                    angle[i] = m - a
                } else {
                    angle[i] = m
                    magnitude[i] = m + a
                }
            } else {
                if a > 0 {
                    angle[i] = m + a
                } else {
                    angle[i] = m
                    magnitude[i] = m - a
                }
            }
        }
    }

    private func applyWindow(_ time: inout [Float], _ window: VorbisWindow) {
        let leftSlope: [Float] = window.leftN == blocksize0 / 2 ? shortSlope : longSlope
        let rightSlope: [Float] = window.rightN == blocksize0 / 2 ? shortSlope : longSlope
        for i in 0..<window.leftStart {
            time[i] = 0
        }
        for i in window.leftStart..<window.leftEnd {
            time[i] *= leftSlope[i - window.leftStart]
        }
        for i in window.rightStart..<window.rightEnd {
            time[i] *= rightSlope[window.rightN - 1 - (i - window.rightStart)]
        }
        for i in window.rightEnd..<time.count {
            time[i] = 0
        }
    }

    /// 前のブロックの右側と、今のブロックの左側を重ねて足す。前の真ん中から今の真ん中までを返す。
    private func overlap(_ blocks: [[Float]], window: VorbisWindow, half: Int) -> [[Float]] {
        var output: [[Float]] = []
        if primed && tails.count == channels {
            for channel in 0..<channels {
                let tail: [Float] = tails[channel]
                let block: [Float] = blocks[channel]
                var samples: [Float] = []
                samples.reserveCapacity(tail.count + half)
                let flat: Int = min(tailFlat, tail.count)
                samples.append(contentsOf: tail[0..<flat])
                let lapped: Int = min(tail.count - flat, window.leftEnd - window.leftStart)
                for k in 0..<lapped {
                    samples.append(tail[flat + k] + block[window.leftStart + k])
                }
                if window.leftEnd < half {
                    samples.append(contentsOf: block[window.leftEnd..<half])
                }
                output.append(samples)
            }
        }
        tails = blocks.map { Array($0[half..<window.rightEnd]) }
        tailFlat = window.rightStart - half
        primed = true
        return output
    }

    /// 3 チャンネル以上を、Vorbis の並び（4.3.9）に合わせて 2 チャンネルにまとめる。
    static func stereo(_ input: [[Float]]) -> [[Float]] {
        let count: Int = input.count
        if count <= 2 { return input }
        let c: Float = 0.7071
        // 左右への重み（並びは 4.3.9。LFE は入れない）
        var lefts: [Float]
        var rights: [Float]
        switch count {
        case 3:
            lefts = [1, c, 0]
            rights = [0, c, 1]
        case 4:
            lefts = [1, 0, c, 0]
            rights = [0, 1, 0, c]
        case 5:
            lefts = [1, c, 0, c, 0]
            rights = [0, c, 1, 0, c]
        case 6:
            lefts = [1, c, 0, c, 0, 0]
            rights = [0, c, 1, 0, c, 0]
        case 7:
            lefts = [1, c, 0, c, 0, 0.5, 0]
            rights = [0, c, 1, 0, c, 0.5, 0]
        case 8:
            lefts = [1, c, 0, c, 0, c, 0, 0]
            rights = [0, c, 1, 0, c, 0, c, 0]
        default:
            lefts = []
            rights = []
            for i in 0..<count {
                lefts.append(i % 2 == 0 ? 1 : 0)
                rights.append(i % 2 == 0 ? 0 : 1)
            }
        }
        let leftSum: Float = lefts.reduce(0, +)
        let rightSum: Float = rights.reduce(0, +)
        let scale: Float = 1 / max(1, max(leftSum, rightSum))
        let length: Int = input.map { $0.count }.min() ?? 0
        var left: [Float] = Array(repeating: 0, count: length)
        var right: [Float] = Array(repeating: 0, count: length)
        for channel in 0..<count {
            let samples: [Float] = input[channel]
            let gl: Float = lefts[channel] * scale
            let gr: Float = rights[channel] * scale
            if gl != 0 {
                for i in 0..<length {
                    left[i] += samples[i] * gl
                }
            }
            if gr != 0 {
                for i in 0..<length {
                    right[i] += samples[i] * gr
                }
            }
        }
        return [left, right]
    }
}

/// ブロックの窓の形（4.3.1）。
struct VorbisWindow {
    let leftStart: Int
    let leftEnd: Int
    let leftN: Int
    let rightStart: Int
    let rightEnd: Int
    let rightN: Int

    init(n: Int, small: Int, long: Bool, previousLong: Bool, nextLong: Bool) {
        let center: Int = n / 2
        if long && !previousLong {
            leftStart = n / 4 - small / 4
            leftEnd = n / 4 + small / 4
            leftN = small / 2
        } else {
            leftStart = 0
            leftEnd = center
            leftN = n / 2
        }
        if long && !nextLong {
            rightStart = n * 3 / 4 - small / 4
            rightEnd = n * 3 / 4 + small / 4
            rightN = small / 2
        } else {
            rightStart = center
            rightEnd = n
            rightN = n / 2
        }
    }
}

struct VorbisMode {
    let long: Bool
    let mapping: Int
}

/// ビットの読み手（下位ビットから順に読む）。
struct VorbisBitReader {
    private let bytes: [UInt8]
    private var position: Int = 0
    private(set) var endOfPacket: Bool = false

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    /// count ビット（0〜32）を符号なしで読む。終わりを越えたら 0 を返して endOfPacket を立てる。
    mutating func read(_ count: Int) -> Int {
        if count <= 0 { return 0 }
        var value: Int = 0
        var shift: Int = 0
        var remaining: Int = count
        while remaining > 0 {
            let index: Int = position >> 3
            if index >= bytes.count {
                endOfPacket = true
                return 0
            }
            let offset: Int = position & 7
            let take: Int = min(8 - offset, remaining)
            let bits: Int = (Int(bytes[index]) >> offset) & ((1 << take) - 1)
            value |= bits << shift
            shift += take
            remaining -= take
            position += take
        }
        return value
    }

    mutating func bit() -> Int {
        let index: Int = position >> 3
        if index >= bytes.count {
            endOfPacket = true
            return 0
        }
        let value: Int = (Int(bytes[index]) >> (position & 7)) & 1
        position += 1
        return value
    }
}

enum VorbisBits {
    /// 値を表すのに要るビット数（ilog(0) = 0, ilog(1) = 1, ilog(4) = 3）。
    static func ilog(_ value: Int) -> Int {
        if value <= 0 { return 0 }
        var bits: Int = 0
        var v: Int = value
        while v > 0 {
            bits += 1
            v >>= 1
        }
        return bits
    }

    /// 32bit の Vorbis の浮動小数（3.2.2）。
    static func float32(_ x: Int) -> Float {
        var mantissa: Double = Double(x & 0x1F_FFFF)
        let exponent: Int = (x & 0x7FE0_0000) >> 21
        if x & 0x8000_0000 != 0 { mantissa = -mantissa }
        return Float(mantissa * pow(2, Double(exponent - 788)))
    }

    /// r^dimensions が entries を超えない最大の r。
    static func lookup1Values(_ entries: Int, _ dimensions: Int) -> Int {
        if dimensions <= 0 { return 0 }
        var r: Int = Int(pow(Double(entries), 1 / Double(dimensions)))
        func power(_ base: Int) -> Double { return pow(Double(base), Double(dimensions)) }
        while power(r + 1) <= Double(entries) { r += 1 }
        while r > 0 && power(r) > Double(entries) { r -= 1 }
        return r
    }
}

/// 符号帳（3 章）。ハフマン木と、VQ の値の表。
struct VorbisCodebook {
    let dimensions: Int
    let entries: Int
    /// 節ごとに 2 つ（0 と 1）。正: 次の節、負: 葉（-(番号+1)）、0: 無し
    private var tree: [Int32] = [0, 0]
    /// VQ の値（entries × dimensions）。lookup の無い符号帳では空
    private(set) var vectors: [Float] = []

    init(_ reader: inout VorbisBitReader) throws {
        guard reader.read(24) == 0x564342 else { throw VorbisDecoder.DecodeError.invalidHeader("符号帳の印がありません") }
        dimensions = reader.read(16)
        entries = reader.read(24)
        guard entries > 0 else { throw VorbisDecoder.DecodeError.invalidHeader("符号帳が空です") }
        var lengths: [Int] = Array(repeating: 0, count: entries)
        if reader.read(1) == 0 {
            let sparse: Bool = reader.read(1) == 1
            for i in 0..<entries {
                if sparse {
                    if reader.read(1) == 1 { lengths[i] = reader.read(5) + 1 }
                } else {
                    lengths[i] = reader.read(5) + 1
                }
            }
        } else {
            var current: Int = 0
            var length: Int = reader.read(5) + 1
            while current < entries {
                let number: Int = reader.read(VorbisBits.ilog(entries - current))
                guard current + number <= entries, length <= 32 else { throw VorbisDecoder.DecodeError.invalidHeader("符号帳の長さが正しくありません") }
                for i in current..<(current + number) {
                    lengths[i] = length
                }
                current += number
                length += 1
                if reader.endOfPacket { break }
            }
        }
        let lookup: Int = reader.read(4)
        if lookup == 1 || lookup == 2 {
            let minimum: Float = VorbisBits.float32(reader.read(32))
            let delta: Float = VorbisBits.float32(reader.read(32))
            let valueBits: Int = reader.read(4) + 1
            let sequence: Bool = reader.read(1) == 1
            let count: Int = lookup == 1 ? VorbisBits.lookup1Values(entries, dimensions) : entries * dimensions
            var multiplicands: [Float] = []
            multiplicands.reserveCapacity(count)
            for _ in 0..<count {
                multiplicands.append(Float(reader.read(valueBits)))
            }
            vectors = VorbisCodebook.unpack(lookup: lookup, entries: entries, dimensions: dimensions, count: count,
                                            multiplicands: multiplicands, minimum: minimum, delta: delta, sequence: sequence)
        } else if lookup != 0 {
            throw VorbisDecoder.DecodeError.invalidHeader("符号帳の lookup の種類が正しくありません")
        }
        if reader.endOfPacket { throw VorbisDecoder.DecodeError.invalidHeader("符号帳が途中で終わっています") }
        try buildTree(lengths)
    }

    private static func unpack(lookup: Int, entries: Int, dimensions: Int, count: Int, multiplicands: [Float],
                               minimum: Float, delta: Float, sequence: Bool) -> [Float] {
        var values: [Float] = Array(repeating: 0, count: entries * dimensions)
        if count == 0 { return values }
        for entry in 0..<entries {
            var last: Float = 0
            var divisor: Int = 1
            for i in 0..<dimensions {
                let offset: Int = lookup == 1 ? (entry / divisor) % count : entry * dimensions + i
                let value: Float = multiplicands[offset] * delta + minimum + last
                values[entry * dimensions + i] = value
                if sequence { last = value }
                if lookup == 1 { divisor *= count }
            }
        }
        return values
    }

    /// 「使われていない一番小さい符号語」を順に割り当てて木を作る（3.2.1）。
    private mutating func buildTree(_ lengths: [Int]) throws {
        var used: [Int] = []
        for i in 0..<entries where lengths[i] > 0 {
            used.append(i)
        }
        if used.isEmpty { return }
        if used.count == 1 {
            // 1 つだけの符号帳は、どちらのビットでもその番号になる
            let leaf: Int32 = -Int32(used[0] + 1)
            tree = [leaf, leaf]
            return
        }
        var available: [UInt64] = Array(repeating: 0, count: 33)
        let first: Int = used[0]
        insert(code: 0, length: lengths[first], entry: first)
        for depth in 1...lengths[first] {
            available[depth] = UInt64(1) << UInt64(32 - depth)
        }
        for entry in used.dropFirst() {
            let length: Int = lengths[entry]
            var depth: Int = length
            while depth > 0 && available[depth] == 0 {
                depth -= 1
            }
            guard depth > 0 else { throw VorbisDecoder.DecodeError.invalidHeader("符号帳の木が多すぎます") }
            let code: UInt64 = available[depth]
            available[depth] = 0
            insert(code: code >> UInt64(32 - length), length: length, entry: entry)
            if depth != length {
                var y: Int = length
                while y > depth {
                    available[y] = code + (UInt64(1) << UInt64(32 - y))
                    y -= 1
                }
            }
        }
    }

    private mutating func insert(code: UInt64, length: Int, entry: Int) {
        var node: Int = 0
        for i in stride(from: length - 1, through: 0, by: -1) {
            let bit: Int = Int((code >> UInt64(i)) & 1)
            let slot: Int = node * 2 + bit
            if i == 0 {
                tree[slot] = -Int32(entry + 1)
                return
            }
            var next: Int = Int(tree[slot])
            if next <= 0 {
                next = tree.count / 2
                tree.append(0)
                tree.append(0)
                tree[slot] = Int32(next)
            }
            node = next
        }
    }

    /// 番号を 1 つ読む（読めなければ -1）。
    func decodeScalar(_ reader: inout VorbisBitReader) -> Int {
        var node: Int = 0
        while true {
            let bit: Int = reader.bit()
            if reader.endOfPacket { return -1 }
            let next: Int32 = tree[node * 2 + bit]
            if next < 0 { return Int(-next) - 1 }
            if next == 0 { return -1 }
            node = Int(next)
        }
    }

    /// VQ の値の先頭の位置（vectors の中）。読めなければ -1。
    func decodeVectorOffset(_ reader: inout VorbisBitReader) -> Int {
        let entry: Int = decodeScalar(&reader)
        if entry < 0 || vectors.isEmpty { return -1 }
        return entry * dimensions
    }
}

/// floor 1（7 章）。
struct VorbisFloor1 {
    let partitionClass: [Int]
    let classDimensions: [Int]
    let classSubclasses: [Int]
    let classMasterbook: [Int]
    let subclassBooks: [[Int]]
    let multiplier: Int
    let xList: [Int]
    let sortedOrder: [Int]
    let lowNeighbor: [Int]
    let highNeighbor: [Int]

    static let inverseDB: [Float] = [
        1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07, 1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
        1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.1287530e-07, 2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
        2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07, 3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
        4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07, 6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
        7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07, 1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
        1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06, 1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
        2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06, 2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
        3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06, 4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
        5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06, 7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
        9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05, 1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
        1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05, 2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
        2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05, 3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
        4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05, 5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
        7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05, 9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
        0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085, 0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
        0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449, 0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
        0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456, 0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
        0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058, 0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
        0.00092223983, 0.00098217216, 0.0010459992, 0.0011139742, 0.0011863665, 0.0012634633, 0.0013455702, 0.0014330129,
        0.0015261382, 0.0016253153, 0.0017309374, 0.0018434235, 0.0019632195, 0.0020908006, 0.0022266726, 0.0023713743,
        0.0025254795, 0.0026895994, 0.0028643847, 0.0030505286, 0.0032487691, 0.0034598925, 0.0036847358, 0.0039241906,
        0.0041792066, 0.0044507950, 0.0047400328, 0.0050480668, 0.0053761186, 0.0057254891, 0.0060975636, 0.0064938176,
        0.0069158225, 0.0073652516, 0.0078438871, 0.0083536271, 0.0088964928, 0.009474637, 0.010090352, 0.010746080,
        0.011444421, 0.012188144, 0.012980198, 0.013823725, 0.014722068, 0.015678791, 0.016697687, 0.017782797,
        0.018938423, 0.020169149, 0.021479854, 0.022875735, 0.024362330, 0.025945531, 0.027631618, 0.029427276,
        0.031339626, 0.033376252, 0.035545228, 0.037855157, 0.040315199, 0.042935108, 0.045725273, 0.048696758,
        0.051861348, 0.055231591, 0.058820850, 0.062643361, 0.066714279, 0.071049749, 0.075666962, 0.080584227,
        0.085821044, 0.091398179, 0.097337747, 0.10366330, 0.11039993, 0.11757434, 0.12521498, 0.13335215,
        0.14201813, 0.15124727, 0.16107617, 0.17154380, 0.18269168, 0.19456402, 0.20720788, 0.22067342,
        0.23501402, 0.25028656, 0.26655159, 0.28387361, 0.30232132, 0.32196786, 0.34289114, 0.36517414,
        0.38890521, 0.41417847, 0.44109412, 0.46975890, 0.50028648, 0.53279791, 0.56742212, 0.60429640,
        0.64356699, 0.68538959, 0.72993007, 0.77736504, 0.82788260, 0.88168307, 0.9389798, 1.0
    ]

    init(_ reader: inout VorbisBitReader, books: [VorbisCodebook]) throws {
        let partitions: Int = reader.read(5)
        var classes: [Int] = []
        var maximumClass: Int = -1
        for _ in 0..<partitions {
            let value: Int = reader.read(4)
            classes.append(value)
            maximumClass = max(maximumClass, value)
        }
        var dimensions: [Int] = []
        var subclasses: [Int] = []
        var masterbooks: [Int] = []
        var subBooks: [[Int]] = []
        if maximumClass >= 0 {
            for _ in 0...maximumClass {
                dimensions.append(reader.read(3) + 1)
                let sub: Int = reader.read(2)
                subclasses.append(sub)
                masterbooks.append(sub != 0 ? reader.read(8) : -1)
                var list: [Int] = []
                for _ in 0..<(1 << sub) {
                    list.append(reader.read(8) - 1)
                }
                subBooks.append(list)
            }
        }
        multiplier = reader.read(2) + 1
        let rangeBits: Int = reader.read(4)
        var xs: [Int] = [0, 1 << rangeBits]
        for partition in classes {
            for _ in 0..<dimensions[partition] {
                xs.append(reader.read(rangeBits))
            }
        }
        if reader.endOfPacket { throw VorbisDecoder.DecodeError.invalidHeader("floor 1 が途中で終わっています") }
        for book in masterbooks where book >= books.count {
            throw VorbisDecoder.DecodeError.invalidHeader("floor 1 の符号帳の番号が正しくありません")
        }
        for list in subBooks {
            for book in list where book >= books.count {
                throw VorbisDecoder.DecodeError.invalidHeader("floor 1 の符号帳の番号が正しくありません")
            }
        }
        partitionClass = classes
        classDimensions = dimensions
        classSubclasses = subclasses
        classMasterbook = masterbooks
        subclassBooks = subBooks
        xList = xs
        sortedOrder = xs.indices.sorted { xs[$0] < xs[$1] }
        var lows: [Int] = [0, 0]
        var highs: [Int] = [0, 0]
        if xs.count > 2 {
            for i in 2..<xs.count {
                var low: Int = 0
                var high: Int = 1
                var lowX: Int = -1
                var highX: Int = Int.max
                for j in 0..<i {
                    let x: Int = xs[j]
                    if x < xs[i] && x > lowX {
                        lowX = x
                        low = j
                    }
                    if x > xs[i] && x < highX {
                        highX = x
                        high = j
                    }
                }
                lows.append(low)
                highs.append(high)
            }
        }
        lowNeighbor = lows
        highNeighbor = highs
    }

    /// パケットから Y の値を読む（7.2.3）。使われていなければ nil。
    func decode(_ reader: inout VorbisBitReader, books: [VorbisCodebook]) -> [Int]? {
        if reader.read(1) == 0 { return nil }
        let range: Int = [256, 128, 86, 64][multiplier - 1]
        let bits: Int = VorbisBits.ilog(range - 1)
        var ys: [Int] = Array(repeating: 0, count: xList.count)
        ys[0] = reader.read(bits)
        ys[1] = reader.read(bits)
        var offset: Int = 2
        for partition in partitionClass {
            let dimensions: Int = classDimensions[partition]
            let subBits: Int = classSubclasses[partition]
            let mask: Int = (1 << subBits) - 1
            var value: Int = 0
            if subBits > 0 {
                value = books[classMasterbook[partition]].decodeScalar(&reader)
                if value < 0 { return nil }
            }
            for j in 0..<dimensions {
                let book: Int = subclassBooks[partition][value & mask]
                value >>= subBits
                if book >= 0 {
                    let y: Int = books[book].decodeScalar(&reader)
                    if y < 0 { return nil }
                    ys[offset + j] = y
                } else {
                    ys[offset + j] = 0
                }
            }
            offset += dimensions
        }
        if reader.endOfPacket { return nil }
        return ys
    }

    /// Y の値から曲線（長さ n）を作り、dB の表で振幅にする（7.2.4）。
    func curve(_ ys: [Int], n: Int) -> [Float] {
        let range: Int = [256, 128, 86, 64][multiplier - 1]
        let count: Int = xList.count
        var finalY: [Int] = Array(repeating: 0, count: count)
        var step2: [Bool] = Array(repeating: false, count: count)
        finalY[0] = ys[0]
        finalY[1] = ys[1]
        step2[0] = true
        step2[1] = true
        if count > 2 {
            for i in 2..<count {
                let low: Int = lowNeighbor[i]
                let high: Int = highNeighbor[i]
                let predicted: Int = VorbisFloor1.renderPoint(xList[low], finalY[low], xList[high], finalY[high], xList[i])
                let value: Int = ys[i]
                let highroom: Int = range - predicted
                let lowroom: Int = predicted
                let room: Int = (highroom < lowroom ? highroom : lowroom) * 2
                if value != 0 {
                    step2[low] = true
                    step2[high] = true
                    step2[i] = true
                    if value >= room {
                        finalY[i] = highroom > lowroom ? value - lowroom + predicted : predicted - value + highroom - 1
                    } else {
                        finalY[i] = value % 2 == 1 ? predicted - (value + 1) / 2 : predicted + value / 2
                    }
                } else {
                    step2[i] = false
                    finalY[i] = predicted
                }
            }
        }
        for i in 0..<count {
            finalY[i] = max(0, min(range - 1, finalY[i]))
        }
        var line: [Int] = Array(repeating: 0, count: n)
        var hx: Int = 0
        var hy: Int = 0
        var lx: Int = 0
        var ly: Int = finalY[sortedOrder[0]] * multiplier
        for k in 1..<count {
            let index: Int = sortedOrder[k]
            if step2[index] {
                hy = finalY[index] * multiplier
                hx = xList[index]
                VorbisFloor1.renderLine(lx, ly, hx, hy, &line)
                lx = hx
                ly = hy
            }
        }
        if hx < n {
            VorbisFloor1.renderLine(hx, hy, n, hy, &line)
        }
        var result: [Float] = Array(repeating: 0, count: n)
        for i in 0..<n {
            result[i] = VorbisFloor1.inverseDB[max(0, min(255, line[i]))]
        }
        return result
    }

    static func renderPoint(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ x: Int) -> Int {
        let dy: Int = y1 - y0
        let adx: Int = x1 - x0
        if adx == 0 { return y0 }
        let err: Int = abs(dy) * (x - x0)
        let off: Int = err / adx
        return dy < 0 ? y0 - off : y0 + off
    }

    /// 整数の線（7.2.4・9.2.7）。x1 は含めない。n を越える所は書かない。
    static func renderLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: inout [Int]) {
        let dy: Int = y1 - y0
        let adx: Int = x1 - x0
        if adx <= 0 { return }
        var ady: Int = abs(dy)
        let base: Int = dy / adx
        let sy: Int = dy < 0 ? base - 1 : base + 1
        var y: Int = y0
        var err: Int = 0
        ady -= abs(base) * adx
        let limit: Int = v.count
        if x0 < limit { v[x0] = y }
        var x: Int = x0 + 1
        while x < x1 {
            err += ady
            if err >= adx {
                err -= adx
                y += sy
            } else {
                y += base
            }
            if x < limit { v[x] = y }
            x += 1
        }
    }
}

/// residue 0・1・2（8 章）。
struct VorbisResidue {
    let type: Int
    let begin: Int
    let end: Int
    let partitionSize: Int
    let classifications: Int
    let classbook: Int
    /// [分類][回] の符号帳（-1 は使わない）
    let books: [[Int]]

    init(_ reader: inout VorbisBitReader, type: Int, books codebooks: [VorbisCodebook]) throws {
        self.type = type
        begin = reader.read(24)
        end = reader.read(24)
        partitionSize = reader.read(24) + 1
        classifications = reader.read(6) + 1
        classbook = reader.read(8)
        var cascades: [Int] = []
        for _ in 0..<classifications {
            let low: Int = reader.read(3)
            let high: Int = reader.read(1) == 1 ? reader.read(5) : 0
            cascades.append(high * 8 + low)
        }
        var list: [[Int]] = []
        for cascade in cascades {
            var row: [Int] = []
            for pass in 0..<8 {
                row.append(cascade & (1 << pass) != 0 ? reader.read(8) : -1)
            }
            list.append(row)
        }
        books = list
        if reader.endOfPacket { throw VorbisDecoder.DecodeError.invalidHeader("residue が途中で終わっています") }
        guard classbook < codebooks.count else { throw VorbisDecoder.DecodeError.invalidHeader("residue の符号帳の番号が正しくありません") }
        for row in list {
            for book in row where book >= codebooks.count || (book >= 0 && codebooks[book].vectors.isEmpty) {
                throw VorbisDecoder.DecodeError.invalidHeader("residue の符号帳が正しくありません")
            }
        }
    }

    /// vectors（長さ n のものが ch 本）に足し込む。skip の印の付いたものは読まない。
    func decode(_ vectors: inout [[Float]], skip: [Bool], n: Int, books codebooks: [VorbisCodebook], reader: inout VorbisBitReader) {
        let ch: Int = vectors.count
        if type == 2 {
            if !skip.contains(false) { return }
            var single: [[Float]] = [Array(repeating: 0, count: n * ch)]
            decodeFormat(&single, skip: [false], size: n * ch, interleave: false, books: codebooks, reader: &reader)
            let joined: [Float] = single[0]
            for i in 0..<n {
                for j in 0..<ch {
                    vectors[j][i] = joined[i * ch + j]
                }
            }
            return
        }
        decodeFormat(&vectors, skip: skip, size: n, interleave: type == 0, books: codebooks, reader: &reader)
    }

    private func decodeFormat(_ vectors: inout [[Float]], skip: [Bool], size: Int, interleave: Bool,
                              books codebooks: [VorbisCodebook], reader: inout VorbisBitReader) {
        let ch: Int = vectors.count
        let limitBegin: Int = min(begin, size)
        let limitEnd: Int = min(end, size)
        let classbookEntry: VorbisCodebook = codebooks[classbook]
        let perCodeword: Int = max(1, classbookEntry.dimensions)
        let toRead: Int = limitEnd - limitBegin
        if toRead <= 0 { return }
        let partitions: Int = toRead / partitionSize
        if partitions == 0 { return }
        var classes: [[Int]] = Array(repeating: Array(repeating: 0, count: partitions + perCodeword), count: ch)
        for pass in 0..<8 {
            var partition: Int = 0
            while partition < partitions {
                if pass == 0 {
                    for j in 0..<ch where !skip[j] {
                        var temp: Int = classbookEntry.decodeScalar(&reader)
                        if temp < 0 { return }
                        for i in stride(from: perCodeword - 1, through: 0, by: -1) {
                            classes[j][i + partition] = temp % classifications
                            temp /= classifications
                        }
                    }
                }
                var i: Int = 0
                while i < perCodeword && partition < partitions {
                    for j in 0..<ch where !skip[j] {
                        let book: Int = books[classes[j][partition]][pass]
                        if book >= 0 {
                            let offset: Int = limitBegin + partition * partitionSize
                            let ok: Bool = VorbisResidue.decodePartition(&vectors[j], offset: offset, size: partitionSize, interleave: interleave,
                                                                       book: codebooks[book], reader: &reader)
                            if !ok { return }
                        }
                    }
                    partition += 1
                    i += 1
                }
            }
        }
    }

    /// 1 つの区切り（8.6.3・8.6.4）。読めなくなったら false。
    private static func decodePartition(_ v: inout [Float], offset: Int, size: Int, interleave: Bool,
                                        book: VorbisCodebook, reader: inout VorbisBitReader) -> Bool {
        let dimensions: Int = book.dimensions
        if dimensions <= 0 { return false }
        let table: [Float] = book.vectors
        if interleave {
            let step: Int = size / dimensions
            for i in 0..<step {
                let start: Int = book.decodeVectorOffset(&reader)
                if start < 0 { return false }
                for j in 0..<dimensions {
                    let index: Int = offset + i + j * step
                    if index < v.count { v[index] += table[start + j] }
                }
            }
        } else {
            var i: Int = 0
            while i < size {
                let start: Int = book.decodeVectorOffset(&reader)
                if start < 0 { return false }
                for j in 0..<dimensions where i < size {
                    let index: Int = offset + i
                    if index < v.count { v[index] += table[start + j] }
                    i += 1
                }
            }
        }
        return true
    }
}

/// mapping 0（9 章）。
struct VorbisMapping {
    let magnitude: [Int]
    let angle: [Int]
    let mux: [Int]
    let submapFloor: [Int]
    let submapResidue: [Int]

    init(_ reader: inout VorbisBitReader, channels: Int, floors: Int, residues: Int) throws {
        let submaps: Int = reader.read(1) == 1 ? reader.read(4) + 1 : 1
        var magnitudes: [Int] = []
        var angles: [Int] = []
        if reader.read(1) == 1 {
            let steps: Int = reader.read(8) + 1
            let bits: Int = VorbisBits.ilog(channels - 1)
            for _ in 0..<steps {
                let m: Int = reader.read(bits)
                let a: Int = reader.read(bits)
                guard m != a, m < channels, a < channels else { throw VorbisDecoder.DecodeError.invalidHeader("チャンネル結合の値が正しくありません") }
                magnitudes.append(m)
                angles.append(a)
            }
        }
        guard reader.read(2) == 0 else { throw VorbisDecoder.DecodeError.invalidHeader("mapping の予約ビットが 0 ではありません") }
        var muxList: [Int] = Array(repeating: 0, count: channels)
        if submaps > 1 {
            for j in 0..<channels {
                let value: Int = reader.read(4)
                guard value < submaps else { throw VorbisDecoder.DecodeError.invalidHeader("mapping の mux が正しくありません") }
                muxList[j] = value
            }
        }
        var floorList: [Int] = []
        var residueList: [Int] = []
        for _ in 0..<submaps {
            _ = reader.read(8)
            let floor: Int = reader.read(8)
            let residue: Int = reader.read(8)
            guard floor < floors, residue < residues else { throw VorbisDecoder.DecodeError.invalidHeader("mapping の番号が正しくありません") }
            floorList.append(floor)
            residueList.append(residue)
        }
        magnitude = magnitudes
        angle = angles
        mux = muxList
        submapFloor = floorList
        submapResidue = residueList
    }
}

/// IMDCT（n 点）。DCT-IV を n/4 点の複素 FFT で求め、並べ替えて n 点にする。係数は掛けない（libvorbis と同じ大きさ）。
final class VorbisIMDCT {
    let size: Int
    private let quarter: Int
    private let preCos: [Float]
    private let preSin: [Float]
    private let postCos: [Float]
    private let postSin: [Float]
    private let fftCos: [Float]
    private let fftSin: [Float]
    private let reversed: [Int]

    init(size n: Int) {
        size = n
        let m: Int = n / 2
        let f: Int = max(1, n / 4)
        quarter = f
        var a: [Float] = []
        var b: [Float] = []
        var c: [Float] = []
        var d: [Float] = []
        for k in 0..<f {
            let pre: Double = Double.pi * Double(k) / Double(m)
            a.append(Float(cos(pre)))
            b.append(Float(-sin(pre)))
            let post: Double = Double.pi * (Double(k) + 0.25) / Double(m)
            c.append(Float(cos(post)))
            d.append(Float(-sin(post)))
        }
        preCos = a
        preSin = b
        postCos = c
        postSin = d
        var wc: [Float] = []
        var ws: [Float] = []
        for j in 0..<max(1, f / 2) {
            let angle: Double = 2 * Double.pi * Double(j) / Double(f)
            wc.append(Float(cos(angle)))
            ws.append(Float(-sin(angle)))
        }
        fftCos = wc
        fftSin = ws
        var bits: Int = 0
        while (1 << bits) < f { bits += 1 }
        var table: [Int] = []
        for i in 0..<f {
            var r: Int = 0
            var v: Int = i
            for _ in 0..<bits {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            table.append(r)
        }
        reversed = table
    }

    /// spectrum（n/2 個）を時間の信号（n 個）にする。
    func inverse(_ spectrum: [Float], into output: inout [Float]) {
        let n: Int = size
        let m: Int = n / 2
        let f: Int = quarter
        var re: [Float] = Array(repeating: 0, count: f)
        var im: [Float] = Array(repeating: 0, count: f)
        for k in 0..<f {
            let a: Float = spectrum[2 * k]
            let b: Float = spectrum[m - 1 - 2 * k]
            let j: Int = reversed[k]
            re[j] = a * preCos[k] - b * preSin[k]
            im[j] = a * preSin[k] + b * preCos[k]
        }
        var length: Int = 2
        while length <= f {
            let halfLength: Int = length / 2
            let stride: Int = f / length
            var start: Int = 0
            while start < f {
                for k in 0..<halfLength {
                    let wr: Float = fftCos[k * stride]
                    let wi: Float = fftSin[k * stride]
                    let p: Int = start + k
                    let q: Int = p + halfLength
                    let tr: Float = re[q] * wr - im[q] * wi
                    let ti: Float = re[q] * wi + im[q] * wr
                    re[q] = re[p] - tr
                    im[q] = im[p] - ti
                    re[p] += tr
                    im[p] += ti
                }
                start += length
            }
            length <<= 1
        }
        var u: [Float] = Array(repeating: 0, count: m)
        for k in 0..<f {
            let wr: Float = re[k] * postCos[k] - im[k] * postSin[k]
            let wi: Float = re[k] * postSin[k] + im[k] * postCos[k]
            u[2 * k] = wr
            u[m - 1 - 2 * k] = -wi
        }
        let h: Int = m / 2
        for i in 0..<h {
            output[i] = u[i + h]
        }
        for i in h..<(3 * h) {
            output[i] = -u[3 * h - 1 - i]
        }
        for i in (3 * h)..<n {
            output[i] = -u[i - 3 * h]
        }
    }

    /// 式どおりの遅い IMDCT（確かめる用）。
    static func slowInverse(_ spectrum: [Float], size n: Int) -> [Float] {
        var output: [Float] = Array(repeating: 0, count: n)
        let m: Int = n / 2
        for i in 0..<n {
            var sum: Double = 0
            for k in 0..<m {
                let angle: Double = 2 * Double.pi / Double(n) * (Double(i) + 0.5 + Double(n) / 4) * (Double(k) + 0.5)
                sum += Double(spectrum[k]) * cos(angle)
            }
            output[i] = Float(sum)
        }
        return output
    }
}
