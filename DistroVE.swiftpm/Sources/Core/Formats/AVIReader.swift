import Foundation

/// AVI の読み手（RIFF）。1GB を超える OpenDML（AVIX のつづき）も順に読む。
final class AVIReader: ForeignDemuxer {
    private struct Stream {
        var track: ForeignTrack
        /// 1 単位の長さは scale / rate 秒
        var scale: Double
        var rate: Double
        /// 0 なら 1 チャンク = 1 単位（可変ビットレート）。それ以外は 1 単位のバイト数
        var sampleSize: Int
        var chunks: Int = 0
        var bytes: Int64 = 0
        /// idx1 の目印（チャンクの順）
        var keyframes: [Bool] = []

        var unit: Double { return rate > 0 ? scale / rate : 0 }
    }

    private let reader: ByteReader
    private var streams: [Stream] = []
    private(set) var duration: Double = 0
    private var moviRanges: [(start: Int64, end: Int64)] = []
    private var current: Int = 0

    var containerName: String { return "AVI" }
    var tracks: [ForeignTrack] { return streams.map { $0.track } }

    init(_ reader: ByteReader) throws {
        self.reader = reader
        try parseSegments()
        if streams.isEmpty { throw ForeignMediaError.broken("ストリームがありません") }
        if moviRanges.isEmpty { throw ForeignMediaError.broken("映像・音声の中身（movi）がありません") }
        reader.seek(to: moviRanges[0].start)
    }

    // MARK: 頭の部分

    private func parseSegments() throws {
        var offset: Int64 = 0
        while offset + 12 <= reader.size {
            reader.seek(to: offset)
            let riff: String = try reader.fourCC()
            let size: Int64 = Int64(try reader.uint(littleEndian: 4))
            let form: String = try reader.fourCC()
            if riff != "RIFF" || (form != "AVI " && form != "AVIX") { break }
            let end: Int64 = min(reader.size, offset + 8 + size)
            try parseChunks(until: end)
            offset = end + (end & 1)
        }
    }

    private func parseChunks(until end: Int64) throws {
        while reader.position + 8 <= end {
            let id: String = try reader.fourCC()
            let size: Int64 = Int64(try reader.uint(littleEndian: 4))
            let dataStart: Int64 = reader.position
            let chunkEnd: Int64 = min(end, dataStart + size)
            if id == "LIST" {
                let type: String = try reader.fourCC()
                if type == "hdrl" {
                    try parseHeaderList(until: chunkEnd)
                } else if type == "movi" {
                    moviRanges.append((reader.position, chunkEnd))
                }
            } else if id == "idx1" {
                try parseIndex(size: Int(size))
            }
            reader.seek(to: chunkEnd + (size & 1))
        }
    }

    private func parseHeaderList(until end: Int64) throws {
        while reader.position + 8 <= end {
            let id: String = try reader.fourCC()
            let size: Int64 = Int64(try reader.uint(littleEndian: 4))
            let chunkEnd: Int64 = min(end, reader.position + size)
            if id == "LIST" {
                let type: String = try reader.fourCC()
                if type == "strl" { try parseStreamList(until: chunkEnd) }
            }
            reader.seek(to: chunkEnd + (size & 1))
        }
    }

    private func parseStreamList(until end: Int64) throws {
        var type: String = ""
        var handler: String = ""
        var scale: Double = 1
        var rate: Double = 0
        var length: Double = 0
        var sampleSize: Int = 0
        var format = Data()
        var name: String = ""
        while reader.position + 8 <= end {
            let id: String = try reader.fourCC()
            let size: Int64 = Int64(try reader.uint(littleEndian: 4))
            let chunkEnd: Int64 = min(end, reader.position + size)
            let data: Data = try reader.read(Int(chunkEnd - reader.position))
            if id == "strh" && data.count >= 48 {
                type = String(decoding: data.prefix(4), as: UTF8.self)
                handler = String(decoding: data.subdata(in: (data.startIndex + 4)..<(data.startIndex + 8)), as: UTF8.self)
                scale = Double(Bytes.littleEndian(data, 20, 4))
                rate = Double(Bytes.littleEndian(data, 24, 4))
                length = Double(Bytes.littleEndian(data, 32, 4))
                sampleSize = Int(Bytes.littleEndian(data, 44, 4))
            } else if id == "strf" {
                format = data
            } else if id == "strn" {
                name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            }
            reader.seek(to: chunkEnd + (size & 1))
        }
        var track: ForeignTrack
        let number: Int = streams.count
        switch type {
        case "vids":
            track = AVIReader.videoTrack(number: number, format: format, handler: handler)
            if rate > 0 { track.defaultDuration = max(1, scale) / rate }
        case "auds":
            track = AVIReader.audioTrack(number: number, format: format)
        default:
            track = ForeignTrack(number: number, kind: .other, codec: .unknown, codecName: type)
        }
        track.name = name
        let stream = Stream(track: track, scale: max(1, scale), rate: rate, sampleSize: sampleSize)
        if type == "vids" && rate > 0 {
            duration = max(duration, length * stream.unit)
        }
        streams.append(stream)
    }

    /// BITMAPINFOHEADER（40 バイト）と、その後ろの設定。
    static func videoTrack(number: Int, format: Data, handler: String) -> ForeignTrack {
        var compression: String = handler
        if format.count >= 20 {
            let code: Data = format.subdata(in: (format.startIndex + 16)..<(format.startIndex + 20))
            let text: String = String(decoding: code, as: UTF8.self)
            if code != Data([0, 0, 0, 0]) || ForeignCodec.fromFourCC(handler) == .unknown { compression = text }
        }
        var track = ForeignTrack(number: number, kind: .video, codec: ForeignCodec.fromFourCC(compression), codecName: compression)
        if track.codec == .unknown { track.codec = ForeignCodec.fromFourCC(handler) }
        if format.count >= 12 {
            track.width = Int(Int32(bitPattern: UInt32(Bytes.littleEndian(format, 4, 4))))
            track.height = abs(Int(Int32(bitPattern: UInt32(Bytes.littleEndian(format, 8, 4)))))
        }
        if format.count > 40 {
            track.codecPrivate = format.subdata(in: (format.startIndex + 40)..<format.endIndex)
        }
        return track
    }

    /// WAVEFORMATEX（18 バイト）と、その後ろの設定。
    static func audioTrack(number: Int, format: Data) -> ForeignTrack {
        var tag: UInt16 = UInt16(Bytes.littleEndian(format, 0, 2))
        let extraSize: Int = Int(Bytes.littleEndian(format, 16, 2))
        if tag == 0xFFFE && format.count >= 26 {
            // WAVE_FORMAT_EXTENSIBLE：SubFormat の GUID の先頭 2 バイトが本当の形式
            tag = UInt16(Bytes.littleEndian(format, 24, 2))
        }
        let codec: ForeignCodec = ForeignCodec.fromWaveTag(tag)
        var track = ForeignTrack(number: number, kind: .audio, codec: codec, codecName: String(format: "0x%04X", tag))
        track.channels = Int(Bytes.littleEndian(format, 2, 2))
        track.sampleRate = Double(Bytes.littleEndian(format, 4, 4))
        track.blockAlign = Int(Bytes.littleEndian(format, 12, 2))
        track.bitsPerSample = Int(Bytes.littleEndian(format, 14, 2))
        track.floatSamples = tag == 0x0003
        if format.count > 18 && extraSize > 0 {
            let end: Int = min(format.count, 18 + extraSize)
            track.codecPrivate = format.subdata(in: (format.startIndex + 18)..<(format.startIndex + end))
        }
        return track
    }

    /// idx1：16 バイトずつ（チャンク ID・フラグ・位置・大きさ）。キーフレームの目印だけを使う。
    private func parseIndex(size: Int) throws {
        let data: Data = try reader.read(size)
        var offset: Int = 0
        while offset + 16 <= data.count {
            let id: String = String(decoding: data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + 4)), as: UTF8.self)
            let flags: UInt64 = Bytes.littleEndian(data, offset + 4, 4)
            if let n = AVIReader.streamNumber(id), n < streams.count, AVIReader.isMediaChunk(id) {
                streams[n].keyframes.append(flags & 0x10 != 0)
            }
            offset += 16
        }
    }

    static func streamNumber(_ id: String) -> Int? {
        let digits: String = String(id.prefix(2))
        guard digits.count == 2, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }

    static func isMediaChunk(_ id: String) -> Bool {
        let kind: String = String(id.suffix(2))
        return kind == "dc" || kind == "db" || kind == "wb"
    }

    // MARK: パケット

    func nextPacket() throws -> ForeignPacket? {
        while current < moviRanges.count {
            let range: (start: Int64, end: Int64) = moviRanges[current]
            if reader.position < range.start { reader.seek(to: range.start) }
            if reader.position + 8 > range.end {
                current += 1
                if current < moviRanges.count { reader.seek(to: moviRanges[current].start) }
                continue
            }
            let id: String = try reader.fourCC()
            let size: Int64 = Int64(try reader.uint(littleEndian: 4))
            if id == "LIST" {
                _ = try reader.fourCC()
                continue
            }
            let chunkEnd: Int64 = min(range.end, reader.position + size)
            guard let number = AVIReader.streamNumber(id), number < streams.count, AVIReader.isMediaChunk(id) else {
                reader.seek(to: chunkEnd + (size & 1))
                continue
            }
            let data: Data = try reader.read(Int(chunkEnd - reader.position))
            reader.seek(to: chunkEnd + (size & 1))
            if let packet = makePacket(number, data) { return packet }
        }
        return nil
    }

    private func makePacket(_ number: Int, _ data: Data) -> ForeignPacket? {
        var stream: Stream = streams[number]
        defer { streams[number] = stream }
        let index: Int = stream.chunks
        stream.chunks += 1
        let unit: Double = stream.unit
        switch stream.track.kind {
        case .video:
            // 大きさ 0 のチャンクは「前のコマのまま」
            if data.isEmpty { return nil }
            let flagged: Bool? = index < stream.keyframes.count ? stream.keyframes[index] : nil
            let keyframe: Bool = flagged ?? AVIReader.isKeyframe(stream.track.codec, data)
            return ForeignPacket(track: number, time: Double(index) * unit, duration: unit, keyframe: keyframe, data: data)
        case .audio:
            if data.isEmpty { return nil }
            if stream.sampleSize > 0 {
                let units: Double = Double(stream.bytes) / Double(stream.sampleSize)
                let length: Double = Double(data.count) / Double(stream.sampleSize) * unit
                stream.bytes += Int64(data.count)
                return ForeignPacket(track: number, time: units * unit, duration: length, keyframe: true, data: data)
            }
            return ForeignPacket(track: number, time: Double(index) * unit, duration: unit, keyframe: true, data: data)
        case .subtitle, .other:
            return nil
        }
    }

    /// 索引がないときに、中身からキーフレームかどうかを見る。
    static func isKeyframe(_ codec: ForeignCodec, _ data: Data) -> Bool {
        let bytes: [UInt8] = [UInt8](data.prefix(4096))
        switch codec {
        case .mpeg4:
            // VOP の開始（00 00 01 B6）の次の 2 ビットが 0 なら I-VOP
            if bytes.count < 5 { return false }
            for i in 0..<(bytes.count - 4) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && bytes[i + 3] == 0xB6 {
                return bytes[i + 4] >> 6 == 0
            }
            return false
        case .h264:
            // NAL の種類 5（IDR）
            if bytes.count < 4 { return false }
            for i in 0..<(bytes.count - 3) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                if bytes[i + 3] & 0x1F == 5 { return true }
            }
            return false
        default:
            return true
        }
    }
}
