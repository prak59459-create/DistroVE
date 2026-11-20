import Foundation

/// iPad の標準の仕組みでは開けない入れ物（MKV・WebM・AVI）を読む（Q71）。
/// FFmpeg は Swift Playgrounds に組み込めないため、入れ物の読み取りは Swift で書き、中身の解読は端末の仕組み（Engine）に任せる。
enum ForeignCodec: String, Codable, Sendable {
    case h264
    case hevc
    case av1
    case vp8
    case vp9
    case mpeg4
    case mjpeg
    case mpeg2
    case theora
    case rawVideo
    case aac
    case mp3
    case mp2
    case ac3
    case eac3
    case opus
    case vorbis
    case flac
    case pcm
    case dts
    case alac
    case srt
    case ass
    case unknown

    var label: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        case .av1: return "AV1"
        case .vp8: return "VP8"
        case .vp9: return "VP9"
        case .mpeg4: return "MPEG-4（Xvid・DivX）"
        case .mjpeg: return "Motion JPEG"
        case .mpeg2: return "MPEG-2"
        case .theora: return "Theora"
        case .rawVideo: return "非圧縮の映像"
        case .aac: return "AAC"
        case .mp3: return "MP3"
        case .mp2: return "MP2"
        case .ac3: return "AC-3"
        case .eac3: return "E-AC-3"
        case .opus: return "Opus"
        case .vorbis: return "Vorbis"
        case .flac: return "FLAC"
        case .pcm: return "PCM"
        case .dts: return "DTS"
        case .alac: return "ALAC"
        case .srt: return "SRT 字幕"
        case .ass: return "ASS 字幕"
        case .unknown: return "不明"
        }
    }

    /// Matroska の CodecID から。
    static func fromMatroska(_ id: String) -> ForeignCodec {
        if id.hasPrefix("A_AAC") { return .aac }
        if id.hasPrefix("A_PCM") { return .pcm }
        if id.hasPrefix("V_MPEG4/ISO/") && id != "V_MPEG4/ISO/AVC" { return .mpeg4 }
        switch id {
        case "V_MPEG4/ISO/AVC": return .h264
        case "V_MPEGH/ISO/HEVC": return .hevc
        case "V_AV1": return .av1
        case "V_VP8": return .vp8
        case "V_VP9": return .vp9
        case "V_MJPEG": return .mjpeg
        case "V_MPEG1", "V_MPEG2": return .mpeg2
        case "V_THEORA": return .theora
        case "V_UNCOMPRESSED": return .rawVideo
        case "A_MPEG/L3": return .mp3
        case "A_MPEG/L2", "A_MPEG/L1": return .mp2
        case "A_AC3": return .ac3
        case "A_EAC3": return .eac3
        case "A_OPUS": return .opus
        case "A_VORBIS": return .vorbis
        case "A_FLAC": return .flac
        case "A_DTS": return .dts
        case "A_ALAC": return .alac
        case "S_TEXT/UTF8": return .srt
        case "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA": return .ass
        default: return .unknown
        }
    }

    /// AVI の映像の FourCC から。
    static func fromFourCC(_ code: String) -> ForeignCodec {
        switch code.uppercased() {
        case "H264", "X264", "AVC1", "DAVC": return .h264
        case "HEVC", "HEV1", "HVC1", "H265", "X265": return .hevc
        case "XVID", "DIVX", "DX50", "FMP4", "MP4V", "M4S2", "3IV2": return .mpeg4
        case "MJPG", "AVRN", "JPEG", "DMB1": return .mjpeg
        case "MPG2", "MPEG", "MPG1", "MX5P": return .mpeg2
        case "VP80": return .vp8
        case "VP90": return .vp9
        case "AV01": return .av1
        case "\u{0}\u{0}\u{0}\u{0}", "RGB ", "DIB ": return .rawVideo
        default: return .unknown
        }
    }

    /// AVI の音声の wFormatTag から。
    static func fromWaveTag(_ tag: UInt16) -> ForeignCodec {
        switch tag {
        case 0x0001, 0x0003, 0xFFFE: return .pcm
        case 0x0055: return .mp3
        case 0x0050: return .mp2
        case 0x2000: return .ac3
        case 0x2001: return .dts
        case 0x00FF, 0x1610, 0x4143, 0x706D: return .aac
        case 0xF1AC: return .flac
        case 0x566F: return .vorbis
        default: return .unknown
        }
    }
}

enum ForeignTrackKind: String, Codable, Sendable {
    case video
    case audio
    case subtitle
    case other
}

/// 入れ物の中の 1 本のトラック。
struct ForeignTrack: Sendable {
    var number: Int
    var kind: ForeignTrackKind
    var codec: ForeignCodec
    /// 入れ物での名前（Matroska の CodecID、AVI の FourCC・wFormatTag）
    var codecName: String
    /// 解読に要る設定（avcC・hvcC・AudioSpecificConfig・OpusHead・VOL など）
    var codecPrivate: Data
    var width: Int = 0
    var height: Int = 0
    var sampleRate: Double = 0
    var channels: Int = 0
    var bitsPerSample: Int = 0
    var blockAlign: Int = 0
    /// PCM の並び（true ならビッグエンディアン、float なら浮動小数）
    var bigEndian: Bool = false
    var floatSamples: Bool = false
    /// 1 コマ（1 パケット）の長さ（秒）。分からなければ 0
    var defaultDuration: Double = 0
    /// 最初の音を捨てる長さ（Opus の前置き。秒）
    var codecDelay: Double = 0
    var language: String = ""
    var name: String = ""
    var isDefault: Bool = true

    init(number: Int, kind: ForeignTrackKind, codec: ForeignCodec, codecName: String, codecPrivate: Data = Data()) {
        self.number = number
        self.kind = kind
        self.codec = codec
        self.codecName = codecName
        self.codecPrivate = codecPrivate
    }

    /// 知らせに使う名前（種類が分からないときは入れ物での名前）。
    var codecLabel: String {
        return codec == .unknown && !codecName.isEmpty ? codecName : codec.label
    }
}

/// 1 つのパケット（映像 1 コマ・音声のかたまり・字幕 1 つ）。
struct ForeignPacket: Sendable {
    var track: Int
    /// 表示する時刻（秒）
    var time: Double
    /// 長さ（秒）。分からなければ 0
    var duration: Double
    var keyframe: Bool
    var data: Data
}

/// 入れ物の読み手。パケットを先頭から順に返す（大きなファイルでも全体を読み込まない）。
protocol ForeignDemuxer: AnyObject {
    var containerName: String { get }
    var duration: Double { get }
    var tracks: [ForeignTrack] { get }
    func nextPacket() throws -> ForeignPacket?
}

enum ForeignMediaError: Error, LocalizedError, Equatable {
    case notRecognized
    case broken(String)

    var errorDescription: String? {
        switch self {
        case .notRecognized: return "MKV・WebM・AVI・Ogg・FLV のどれでもありません。"
        case .broken(let detail): return "ファイルが壊れているか、対応していない作りです（\(detail)）。"
        }
    }
}

enum ForeignContainer {
    static let extensions: Set<String> = ["mkv", "mka", "mks", "webm", "avi", "ogg", "oga", "ogv", "opus", "flv"]

    /// 先頭のしるしで入れ物を見分けて開く。
    static func open(url: URL) throws -> ForeignDemuxer {
        let reader = try ByteReader(url: url)
        return try open(reader)
    }

    static func open(data: Data) throws -> ForeignDemuxer {
        return try open(ByteReader(data: data))
    }

    static func open(_ reader: ByteReader) throws -> ForeignDemuxer {
        let head: Data = try reader.peek(12)
        if head.count >= 4 && head.prefix(4) == Data([0x1A, 0x45, 0xDF, 0xA3]) {
            return try MatroskaReader(reader)
        }
        if head.count >= 12 && head.prefix(4) == Data("RIFF".utf8) && head.subdata(in: 8..<12) == Data("AVI ".utf8) {
            return try AVIReader(reader)
        }
        if head.count >= 4 && head.prefix(4) == Data("OggS".utf8) {
            return try OggReader(reader)
        }
        if head.count >= 4 && head.prefix(3) == Data("FLV".utf8) && head[head.startIndex + 3] == 1 {
            return try FLVReader(reader)
        }
        throw ForeignMediaError.notRecognized
    }

    /// 字幕トラックのパケットを字幕にする（SRT はそのまま、ASS は飾りの命令を取る）。
    static func cues(from packets: [ForeignPacket], codec: ForeignCodec) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        for packet in packets {
            let raw: String = String(decoding: packet.data, as: UTF8.self)
            let text: String = codec == .ass ? ForeignContainer.assText(raw) : raw
            let trimmed: String = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let start = Time(seconds: packet.time)
            let length: Double = packet.duration > 0 ? packet.duration : 2
            result.append(SubtitleCue(start: start, end: Time(seconds: packet.time + length), text: trimmed))
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Matroska の ASS のブロック「ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text」から本文を取り出す。
    static func assText(_ line: String) -> String {
        let parts: [Substring] = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        let body: String = parts.count == 9 ? String(parts[8]) : line
        var result: String = ""
        var depth: Int = 0
        for ch in body {
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(ch)
            }
        }
        return result.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
    }
}

/// ファイルかメモリを先頭から読む（ファイルは 1MB ずつ読み込む）。
final class ByteReader {
    private let handle: FileHandle?
    private let memory: Data?
    private var buffer: Data = Data()
    private var bufferStart: Int64 = 0
    private(set) var position: Int64 = 0
    let size: Int64
    private static let chunk: Int = 1 << 20

    init(url: URL) throws {
        let handle: FileHandle = try FileHandle(forReadingFrom: url)
        self.handle = handle
        self.memory = nil
        let end: UInt64 = try handle.seekToEnd()
        self.size = Int64(end)
        try handle.seek(toOffset: 0)
    }

    init(data: Data) {
        self.handle = nil
        self.memory = data
        self.size = Int64(data.count)
    }

    deinit {
        try? handle?.close()
    }

    var remaining: Int64 { return size - position }
    var isAtEnd: Bool { return position >= size }

    func seek(to offset: Int64) {
        position = max(0, min(size, offset))
    }

    func skip(_ count: Int64) {
        seek(to: position + count)
    }

    /// count バイト（足りなければあるだけ）を読む。
    func read(_ count: Int) throws -> Data {
        let wanted: Int = Int(min(Int64(max(0, count)), remaining))
        if wanted == 0 { return Data() }
        if let data = memory {
            let start: Int = Int(position)
            position += Int64(wanted)
            return data.subdata(in: start..<(start + wanted))
        }
        if wanted > ByteReader.chunk {
            return try readDirect(wanted)
        }
        try fill(wanted)
        let offset: Int = Int(position - bufferStart)
        let result: Data = buffer.subdata(in: offset..<(offset + wanted))
        position += Int64(wanted)
        return result
    }

    func peek(_ count: Int) throws -> Data {
        let start: Int64 = position
        let data: Data = try read(count)
        position = start
        return data
    }

    func readByte() throws -> UInt8 {
        let data: Data = try read(1)
        guard let byte = data.first else { throw ForeignMediaError.broken("途中で終わっています") }
        return byte
    }

    private func fill(_ wanted: Int) throws {
        let have: Int64 = bufferStart + Int64(buffer.count)
        if position >= bufferStart && position + Int64(wanted) <= have { return }
        guard let handle = handle else { return }
        try handle.seek(toOffset: UInt64(position))
        let length: Int = max(ByteReader.chunk, wanted)
        buffer = try handle.read(upToCount: length) ?? Data()
        bufferStart = position
    }

    private func readDirect(_ count: Int) throws -> Data {
        guard let handle = handle else { return Data() }
        try handle.seek(toOffset: UInt64(position))
        let data: Data = try handle.read(upToCount: count) ?? Data()
        position += Int64(data.count)
        return data
    }

    // MARK: 数の読み取り

    func uint(littleEndian bytes: Int) throws -> UInt64 {
        let data: Data = try read(bytes)
        if data.count < bytes { throw ForeignMediaError.broken("途中で終わっています") }
        var value: UInt64 = 0
        for (i, byte) in data.enumerated() {
            value |= UInt64(byte) << UInt64(8 * i)
        }
        return value
    }

    func fourCC() throws -> String {
        let data: Data = try read(4)
        return String(decoding: data, as: UTF8.self)
    }
}

/// バイト列から数を読む小さな道具。
enum Bytes {
    static func bigEndian(_ data: Data) -> UInt64 {
        var value: UInt64 = 0
        for byte in data {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    static func littleEndian(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        var value: UInt64 = 0
        let base: Int = data.startIndex + offset
        if offset < 0 || offset + count > data.count { return 0 }
        for i in 0..<count {
            value |= UInt64(data[base + i]) << UInt64(8 * i)
        }
        return value
    }

    static func float(_ data: Data) -> Double {
        let bits: UInt64 = Bytes.bigEndian(data)
        if data.count == 4 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits))) }
        if data.count == 8 { return Double(bitPattern: bits) }
        return 0
    }
}
