import Foundation

/// Matroska（MKV）と WebM の読み手（EBML）。仕様: RFC 9559。
final class MatroskaReader: ForeignDemuxer {
    // 要素の ID（目印のビットを含めた値）
    enum ID {
        static let ebml: UInt64 = 0x1A45DFA3
        static let docType: UInt64 = 0x4282
        static let segment: UInt64 = 0x18538067
        static let info: UInt64 = 0x1549A966
        static let timecodeScale: UInt64 = 0x2AD7B1
        static let duration: UInt64 = 0x4489
        static let tracks: UInt64 = 0x1654AE6B
        static let trackEntry: UInt64 = 0xAE
        static let trackNumber: UInt64 = 0xD7
        static let trackType: UInt64 = 0x83
        static let codecID: UInt64 = 0x86
        static let codecPrivate: UInt64 = 0x63A2
        static let defaultDuration: UInt64 = 0x23E383
        static let codecDelay: UInt64 = 0x56AA
        static let language: UInt64 = 0x22B59C
        static let languageIETF: UInt64 = 0x22B59D
        static let name: UInt64 = 0x536E
        static let flagDefault: UInt64 = 0x88
        static let video: UInt64 = 0xE0
        static let pixelWidth: UInt64 = 0xB0
        static let pixelHeight: UInt64 = 0xBA
        static let audio: UInt64 = 0xE1
        static let samplingFrequency: UInt64 = 0xB5
        static let channels: UInt64 = 0x9F
        static let bitDepth: UInt64 = 0x6264
        static let contentEncodings: UInt64 = 0x6D80
        static let contentEncoding: UInt64 = 0x6240
        static let contentCompression: UInt64 = 0x5034
        static let contentCompAlgo: UInt64 = 0x4254
        static let contentCompSettings: UInt64 = 0x4255
        static let cluster: UInt64 = 0x1F43B675
        static let clusterTimecode: UInt64 = 0xE7
        static let simpleBlock: UInt64 = 0xA3
        static let blockGroup: UInt64 = 0xA0
        static let block: UInt64 = 0xA1
        static let blockDuration: UInt64 = 0x9B
        static let referenceBlock: UInt64 = 0xFB
        static let cues: UInt64 = 0x1C53BB6B
        static let tags: UInt64 = 0x1254C367
        static let chapters: UInt64 = 0x1043A770
        static let attachments: UInt64 = 0x1941A469
        static let seekHead: UInt64 = 0x114D9B74
    }

    /// Segment の直下に来る要素（大きさ不明のクラスターの終わりを見分ける）
    private static let topLevel: Set<UInt64> = [ID.cluster, ID.cues, ID.tags, ID.chapters, ID.attachments, ID.seekHead, ID.info, ID.tracks]

    private struct Header {
        let id: UInt64
        /// nil なら大きさ不明（最後まで、または次の上位の要素まで）
        let size: Int64?
        let start: Int64
        let dataStart: Int64
    }

    private let reader: ByteReader
    private(set) var docType: String = "matroska"
    private(set) var duration: Double = 0
    private(set) var tracks: [ForeignTrack] = []
    private var timecodeScale: Double = 1_000_000
    private var segmentEnd: Int64
    private var clusterEnd: Int64?
    private var inCluster: Bool = false
    private var clusterUnknown: Bool = false
    private var clusterTime: Int64 = 0
    private var pending: [ForeignPacket] = []
    /// ヘッダーの削られた部分（ContentCompAlgo 3）。トラック番号 → 足す前置き
    private var strippedHeaders: [Int: Data] = [:]

    var containerName: String { return docType == "webm" ? "WebM" : "MKV" }

    init(_ reader: ByteReader) throws {
        self.reader = reader
        self.segmentEnd = reader.size
        try readHeaders()
    }

    // MARK: EBML の基本

    /// 可変長の数。keepMarker なら先頭の目印ビットを残す（要素の ID）。
    static func readVInt(_ reader: ByteReader, keepMarker: Bool) throws -> (value: UInt64, length: Int, unknown: Bool) {
        let first: UInt8 = try reader.readByte()
        if first == 0 { throw ForeignMediaError.broken("EBML の数が読めません") }
        var length: Int = 1
        var mask: UInt8 = 0x80
        while first & mask == 0 {
            length += 1
            mask >>= 1
        }
        var value: UInt64 = UInt64(keepMarker ? first : first & (mask &- 1))
        if length > 1 {
            let rest: Data = try reader.read(length - 1)
            if rest.count < length - 1 { throw ForeignMediaError.broken("途中で終わっています") }
            for byte in rest {
                value = (value << 8) | UInt64(byte)
            }
        }
        let allOnes: UInt64 = (UInt64(1) << UInt64(7 * length)) - 1
        return (value, length, !keepMarker && value == allOnes)
    }

    private func readHeader() throws -> Header {
        let start: Int64 = reader.position
        let id: (value: UInt64, length: Int, unknown: Bool) = try MatroskaReader.readVInt(reader, keepMarker: true)
        let size: (value: UInt64, length: Int, unknown: Bool) = try MatroskaReader.readVInt(reader, keepMarker: false)
        let length: Int64? = size.unknown ? nil : Int64(min(size.value, UInt64(Int64.max)))
        return Header(id: id.value, size: length, start: start, dataStart: reader.position)
    }

    private func end(of header: Header, parentEnd: Int64) -> Int64 {
        guard let size = header.size else { return parentEnd }
        return min(parentEnd, header.dataStart + size)
    }

    private func readUInt(_ header: Header) throws -> UInt64 {
        let size: Int = Int(min(8, header.size ?? 0))
        return Bytes.bigEndian(try reader.read(size))
    }

    private func readString(_ header: Header) throws -> String {
        let data: Data = try reader.read(Int(header.size ?? 0))
        let trimmed: Data = data.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    // MARK: 頭の部分（Info・Tracks）

    private func readHeaders() throws {
        let ebml: Header = try readHeader()
        if ebml.id != ID.ebml { throw ForeignMediaError.notRecognized }
        let ebmlEnd: Int64 = end(of: ebml, parentEnd: reader.size)
        while reader.position < ebmlEnd {
            let child: Header = try readHeader()
            if child.id == ID.docType {
                docType = try readString(child)
            }
            reader.seek(to: end(of: child, parentEnd: ebmlEnd))
        }
        reader.seek(to: ebmlEnd)
        var segment: Header = try readHeader()
        while segment.id != ID.segment {
            reader.seek(to: end(of: segment, parentEnd: reader.size))
            if reader.isAtEnd { throw ForeignMediaError.broken("Segment がありません") }
            segment = try readHeader()
        }
        segmentEnd = end(of: segment, parentEnd: reader.size)
        // 最初のクラスターまでの Info と Tracks を読む
        while reader.position < segmentEnd {
            let child: Header = try readHeader()
            if child.id == ID.cluster {
                reader.seek(to: child.start)
                break
            }
            let childEnd: Int64 = end(of: child, parentEnd: segmentEnd)
            if child.id == ID.info {
                try readInfo(until: childEnd)
            } else if child.id == ID.tracks {
                try readTracks(until: childEnd)
            }
            reader.seek(to: childEnd)
        }
        if tracks.isEmpty { throw ForeignMediaError.broken("トラックがありません") }
    }

    private func readInfo(until limit: Int64) throws {
        var rawDuration: Double = 0
        while reader.position < limit {
            let child: Header = try readHeader()
            if child.id == ID.timecodeScale {
                timecodeScale = Double(try readUInt(child))
            } else if child.id == ID.duration {
                rawDuration = Bytes.float(try reader.read(Int(child.size ?? 0)))
            }
            reader.seek(to: end(of: child, parentEnd: limit))
        }
        duration = rawDuration * timecodeScale / 1_000_000_000
    }

    private func readTracks(until limit: Int64) throws {
        while reader.position < limit {
            let child: Header = try readHeader()
            let childEnd: Int64 = end(of: child, parentEnd: limit)
            if child.id == ID.trackEntry {
                if let track = try readTrackEntry(until: childEnd) { tracks.append(track) }
            }
            reader.seek(to: childEnd)
        }
    }

    private func readTrackEntry(until limit: Int64) throws -> ForeignTrack? {
        var track = ForeignTrack(number: 0, kind: .other, codec: .unknown, codecName: "")
        var type: UInt64 = 0
        var compression: (algorithm: UInt64, settings: Data) = (0, Data())
        while reader.position < limit {
            let child: Header = try readHeader()
            let childEnd: Int64 = end(of: child, parentEnd: limit)
            switch child.id {
            case ID.trackNumber: track.number = Int(try readUInt(child))
            case ID.trackType: type = try readUInt(child)
            case ID.codecID: track.codecName = try readString(child)
            case ID.codecPrivate: track.codecPrivate = try reader.read(Int(child.size ?? 0))
            case ID.defaultDuration: track.defaultDuration = Double(try readUInt(child)) / 1_000_000_000
            case ID.codecDelay: track.codecDelay = Double(try readUInt(child)) / 1_000_000_000
            case ID.language: if track.language.isEmpty { track.language = try readString(child) }
            case ID.languageIETF: track.language = try readString(child)
            case ID.name: track.name = try readString(child)
            case ID.flagDefault: track.isDefault = try readUInt(child) != 0
            case ID.video: try readVideo(&track, until: childEnd)
            case ID.audio: try readAudio(&track, until: childEnd)
            case ID.contentEncodings: compression = try readEncodings(until: childEnd)
            default: break
            }
            reader.seek(to: childEnd)
        }
        if track.number == 0 { return nil }
        if compression.algorithm == 3 && !compression.settings.isEmpty {
            strippedHeaders[track.number] = compression.settings
        }
        track.codec = ForeignCodec.fromMatroska(track.codecName)
        switch type {
        case 1: track.kind = .video
        case 2: track.kind = .audio
        case 17: track.kind = .subtitle
        default: track.kind = .other
        }
        if track.codec == .pcm {
            track.bigEndian = track.codecName == "A_PCM/INT/BIG"
            track.floatSamples = track.codecName == "A_PCM/FLOAT/IEEE"
        }
        return track
    }

    private func readVideo(_ track: inout ForeignTrack, until limit: Int64) throws {
        while reader.position < limit {
            let child: Header = try readHeader()
            if child.id == ID.pixelWidth {
                track.width = Int(try readUInt(child))
            } else if child.id == ID.pixelHeight {
                track.height = Int(try readUInt(child))
            }
            reader.seek(to: end(of: child, parentEnd: limit))
        }
    }

    private func readAudio(_ track: inout ForeignTrack, until limit: Int64) throws {
        track.sampleRate = 8000
        track.channels = 1
        while reader.position < limit {
            let child: Header = try readHeader()
            switch child.id {
            case ID.samplingFrequency: track.sampleRate = Bytes.float(try reader.read(Int(child.size ?? 0)))
            case ID.channels: track.channels = Int(try readUInt(child))
            case ID.bitDepth: track.bitsPerSample = Int(try readUInt(child))
            default: break
            }
            reader.seek(to: end(of: child, parentEnd: limit))
        }
    }

    /// ヘッダーの削除（ContentCompAlgo 3）だけに対応する。zlib などの圧縮は読めない。
    private func readEncodings(until limit: Int64) throws -> (algorithm: UInt64, settings: Data) {
        var algorithm: UInt64 = 0
        var settings = Data()
        var depth: [Int64] = [limit]
        while let current = depth.last {
            if reader.position >= current {
                depth.removeLast()
                continue
            }
            let child: Header = try readHeader()
            let childEnd: Int64 = end(of: child, parentEnd: current)
            switch child.id {
            case ID.contentEncoding, ID.contentCompression:
                depth.append(childEnd)
                continue
            case ID.contentCompAlgo: algorithm = try readUInt(child)
            case ID.contentCompSettings: settings = try reader.read(Int(child.size ?? 0))
            default: break
            }
            reader.seek(to: childEnd)
        }
        return (algorithm, settings)
    }

    // MARK: パケット

    func nextPacket() throws -> ForeignPacket? {
        while true {
            if !pending.isEmpty { return pending.removeFirst() }
            if inCluster {
                if let packet = try readClusterChild() { return packet }
                continue
            }
            if reader.position >= segmentEnd || reader.remaining < 2 { return nil }
            let header: Header = try readHeader()
            if header.id == ID.cluster {
                inCluster = true
                clusterUnknown = header.size == nil
                clusterEnd = header.size.map { header.dataStart + $0 }
                continue
            }
            reader.seek(to: end(of: header, parentEnd: segmentEnd))
            if header.size == nil { return nil }
        }
    }

    /// クラスターの中の要素を 1 つ読む。ブロックならパケットを返す。
    private func readClusterChild() throws -> ForeignPacket? {
        let limit: Int64 = clusterEnd ?? segmentEnd
        if reader.position >= limit || reader.remaining < 2 {
            inCluster = false
            return nil
        }
        let header: Header = try readHeader()
        if clusterUnknown && MatroskaReader.topLevel.contains(header.id) {
            reader.seek(to: header.start)
            inCluster = false
            return nil
        }
        let childEnd: Int64 = end(of: header, parentEnd: limit)
        defer { reader.seek(to: childEnd) }
        switch header.id {
        case ID.clusterTimecode:
            clusterTime = Int64(try readUInt(header))
            return nil
        case ID.simpleBlock:
            let data: Data = try reader.read(Int(header.size ?? 0))
            try parseBlock(data, simple: true, blockDuration: nil, hasReference: false)
        case ID.blockGroup:
            try readBlockGroup(until: childEnd)
        default:
            return nil
        }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func readBlockGroup(until limit: Int64) throws {
        var block = Data()
        var blockDuration: UInt64?
        var hasReference: Bool = false
        while reader.position < limit {
            let child: Header = try readHeader()
            switch child.id {
            case ID.block: block = try reader.read(Int(child.size ?? 0))
            case ID.blockDuration: blockDuration = try readUInt(child)
            case ID.referenceBlock: hasReference = true
            default: break
            }
            reader.seek(to: end(of: child, parentEnd: limit))
        }
        if !block.isEmpty {
            try parseBlock(block, simple: false, blockDuration: blockDuration, hasReference: hasReference)
        }
    }

    /// ブロック：トラック番号（可変長）・相対時刻（16bit）・フラグ・（まとめ方の情報）・中身。
    private func parseBlock(_ data: Data, simple: Bool, blockDuration: UInt64?, hasReference: Bool) throws {
        let block = ByteReader(data: data)
        let number: Int = Int(try MatroskaReader.readVInt(block, keepMarker: false).value)
        let timeData: Data = try block.read(2)
        if timeData.count < 2 { throw ForeignMediaError.broken("ブロックが短すぎます") }
        let relative: Int16 = Int16(bitPattern: UInt16(timeData[timeData.startIndex]) << 8 | UInt16(timeData[timeData.startIndex + 1]))
        let flags: UInt8 = try block.readByte()
        let keyframe: Bool = simple ? (flags & 0x80) != 0 : !hasReference
        let lacing: UInt8 = (flags >> 1) & 0x03
        let frames: [Data] = try MatroskaReader.unlace(block, lacing: lacing)
        guard let track = tracks.first(where: { $0.number == number }) else { return }
        let base: Double = Double(clusterTime + Int64(relative)) * timecodeScale / 1_000_000_000
        var frameDuration: Double = track.defaultDuration
        if let d = blockDuration, frames.count > 0 {
            frameDuration = Double(d) * timecodeScale / 1_000_000_000 / Double(frames.count)
        }
        let prefix: Data? = strippedHeaders[number]
        for (i, frame) in frames.enumerated() {
            var payload: Data = frame
            if let p = prefix { payload = p + frame }
            let time: Double = base + Double(i) * frameDuration
            pending.append(ForeignPacket(track: number, time: time, duration: frameDuration, keyframe: keyframe || track.kind != .video, data: payload))
        }
    }

    /// まとめ方（なし・Xiph・固定長・EBML）を解いて、1 つずつの中身にする。
    static func unlace(_ block: ByteReader, lacing: UInt8) throws -> [Data] {
        if lacing == 0 {
            return [try block.read(Int(block.remaining))]
        }
        let count: Int = Int(try block.readByte()) + 1
        var sizes: [Int] = []
        switch lacing {
        case 1:
            for _ in 0..<(count - 1) {
                var size: Int = 0
                var byte: UInt8 = 255
                while byte == 255 {
                    byte = try block.readByte()
                    size += Int(byte)
                }
                sizes.append(size)
            }
        case 3:
            if count > 1 {
                let first: Int = Int(try MatroskaReader.readVInt(block, keepMarker: false).value)
                sizes.append(first)
                var previous: Int = first
                for _ in 0..<(count - 2) {
                    // 前の大きさとの差（符号付き）
                    let raw: (value: UInt64, length: Int, unknown: Bool) = try MatroskaReader.readVInt(block, keepMarker: false)
                    let bias: Int64 = (Int64(1) << Int64(7 * raw.length - 1)) - 1
                    let size: Int = previous + Int(Int64(raw.value) - bias)
                    sizes.append(size)
                    previous = size
                }
            }
        default:
            let each: Int = Int(block.remaining) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let used: Int = sizes.reduce(0, +)
        sizes.append(max(0, Int(block.remaining) - used))
        var frames: [Data] = []
        for size in sizes {
            frames.append(try block.read(size))
        }
        return frames
    }
}
