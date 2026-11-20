import Foundation

/// FLV の読み手（Q71）。古い OBS の録画や、ネットから保存した動画に多い。
/// 映像は H.264・HEVC（旧来の番号 12 と、拡張 RTMP の FourCC）・AV1・VP9、音声は AAC・MP3・PCM・Opus・FLAC・AC-3。
/// Sorenson Spark・VP6・Nellymoser・Speex など Flash だけの形式はトラックとして見せて「読めない」と伝える。
final class FLVReader: ForeignDemuxer {
    static let videoNumber: Int = 1
    static let audioNumber: Int = 2

    private let reader: ByteReader
    private(set) var tracks: [ForeignTrack] = []
    private(set) var duration: Double = 0
    var containerName: String { return "FLV" }

    private var video: ForeignTrack?
    private var audio: ForeignTrack?
    private var queue: [ForeignPacket] = []
    private var finished: Bool = false
    private var sawVideoFrame: Bool = false
    private var sawAudioFrame: Bool = false

    private struct Tag {
        let type: Int
        /// 解読する順の時刻（ミリ秒）
        let time: Int
        let data: Data
    }

    init(_ reader: ByteReader) throws {
        self.reader = reader
        let header: Data = try reader.read(9)
        guard header.count == 9, header.prefix(3) == Data("FLV".utf8) else { throw ForeignMediaError.notRecognized }
        let flags: UInt8 = header[header.startIndex + 4]
        let headerSize: Int = Int(Bytes.bigEndian(header.subdata(in: (header.startIndex + 5)..<(header.startIndex + 9))))
        reader.seek(to: Int64(max(9, headerSize)))
        reader.skip(4)
        let wantsVideo: Bool = flags & 0x01 != 0
        let wantsAudio: Bool = flags & 0x04 != 0
        var metadataDuration: Double = 0
        var scanned: Int = 0
        // 設定（シーケンスヘッダー）が出そろうまで読む。そのあいだの映像・音声は queue に入る
        while scanned < 120 && !finished {
            guard let tag = try readTag() else { break }
            scanned += 1
            if tag.type == 18 {
                metadataDuration = max(metadataDuration, FLVReader.metadataDuration(tag.data))
            } else {
                handle(tag)
            }
            let videoReady: Bool = !wantsVideo || sawVideoFrame
            let audioReady: Bool = !wantsAudio || sawAudioFrame
            if videoReady && audioReady && (sawVideoFrame || sawAudioFrame) { break }
        }
        if let track = video { tracks.append(track) }
        if let track = audio { tracks.append(track) }
        if tracks.isEmpty { throw ForeignMediaError.broken("FLV に映像も音声もありません") }
        duration = metadataDuration > 0 ? metadataDuration : lastTagTime()
    }

    func nextPacket() throws -> ForeignPacket? {
        while queue.isEmpty && !finished {
            guard let tag = try readTag() else { break }
            if tag.type != 18 { handle(tag) }
        }
        if queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    // MARK: タグ

    private func readTag() throws -> Tag? {
        let head: Data = try reader.read(11)
        if head.count < 11 {
            finished = true
            return nil
        }
        let b: [UInt8] = [UInt8](head)
        let type: Int = Int(b[0] & 0x1F)
        let size: Int = (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
        let low: Int = (Int(b[4]) << 16) | (Int(b[5]) << 8) | Int(b[6])
        let time: Int = low | (Int(b[7]) << 24)
        let data: Data = try reader.read(size)
        reader.skip(4)
        if data.count < size {
            finished = true
            return nil
        }
        if b[0] & 0x20 != 0 { return Tag(type: 0, time: time, data: Data()) }
        return Tag(type: type, time: time, data: data)
    }

    private func handle(_ tag: Tag) {
        if tag.data.isEmpty { return }
        if tag.type == 9 {
            handleVideo(tag)
        } else if tag.type == 8 {
            handleAudio(tag)
        }
    }

    private static func int24(_ data: Data, _ offset: Int) -> Int {
        let base: Int = data.startIndex + offset
        if offset + 3 > data.count { return 0 }
        let value: Int = (Int(data[base]) << 16) | (Int(data[base + 1]) << 8) | Int(data[base + 2])
        return value & 0x80_0000 != 0 ? value - 0x100_0000 : value
    }

    private static func tail(_ data: Data, from offset: Int) -> Data {
        if offset >= data.count { return Data() }
        return data.subdata(in: (data.startIndex + offset)..<data.endIndex)
    }

    private func handleVideo(_ tag: Tag) {
        let data: Data = tag.data
        let first: UInt8 = data[data.startIndex]
        var codec: ForeignCodec = .unknown
        var name: String = ""
        var keyframe: Bool = false
        var config: Data?
        var payload: Data?
        var composition: Int = 0
        if first & 0x80 != 0 {
            // 拡張 RTMP：上位 1 ビットが印、続く 3 ビットがコマの種類、下位 4 ビットがパケットの種類、そのあと FourCC
            keyframe = (first >> 4) & 0x7 == 1
            let packetType: UInt8 = first & 0x0F
            if data.count < 5 { return }
            let fourCC: String = String(decoding: data.subdata(in: (data.startIndex + 1)..<(data.startIndex + 5)), as: UTF8.self)
            name = fourCC
            switch fourCC {
            case "avc1": codec = .h264
            case "hvc1": codec = .hevc
            case "av01": codec = .av1
            case "vp09": codec = .vp9
            case "vp08": codec = .vp8
            default: codec = .unknown
            }
            let hasComposition: Bool = codec == .h264 || codec == .hevc
            switch packetType {
            case 0:
                config = FLVReader.tail(data, from: 5)
            case 1:
                if hasComposition {
                    composition = FLVReader.int24(data, 5)
                    payload = FLVReader.tail(data, from: 8)
                } else {
                    payload = FLVReader.tail(data, from: 5)
                }
            case 3:
                payload = FLVReader.tail(data, from: 5)
            default:
                return
            }
        } else {
            let frameType: Int = Int(first >> 4)
            if frameType == 5 { return }
            keyframe = frameType == 1
            let id: Int = Int(first & 0x0F)
            switch id {
            case 7, 12:
                codec = id == 7 ? .h264 : .hevc
                if data.count < 5 { return }
                let packetType: UInt8 = data[data.startIndex + 1]
                composition = FLVReader.int24(data, 2)
                if packetType == 0 {
                    config = FLVReader.tail(data, from: 5)
                } else if packetType == 1 {
                    payload = FLVReader.tail(data, from: 5)
                } else {
                    return
                }
            case 2: name = "Sorenson Spark（H.263）"
            case 3, 6: name = "Screen Video"
            case 4, 5: name = "On2 VP6"
            default: name = "映像の番号 \(id)"
            }
            if codec == .unknown { payload = FLVReader.tail(data, from: 1) }
        }
        if video == nil {
            var track = ForeignTrack(number: FLVReader.videoNumber, kind: .video, codec: codec, codecName: name)
            track.isDefault = true
            video = track
        }
        if let made = config {
            video?.codecPrivate = made
            return
        }
        guard let frame = payload, !frame.isEmpty else { return }
        sawVideoFrame = true
        let time: Double = Double(tag.time + composition) / 1000
        queue.append(ForeignPacket(track: FLVReader.videoNumber, time: time, duration: 0, keyframe: keyframe, data: frame))
    }

    private func handleAudio(_ tag: Tag) {
        let data: Data = tag.data
        let first: UInt8 = data[data.startIndex]
        let format: Int = Int(first >> 4)
        let rates: [Double] = [5_512.5, 11_025, 22_050, 44_100]
        let rate: Double = rates[Int((first >> 2) & 0x3)]
        let sixteen: Bool = (first >> 1) & 1 == 1
        let stereo: Bool = first & 1 == 1
        var codec: ForeignCodec = .unknown
        var name: String = ""
        var config: Data?
        var payload: Data?
        switch format {
        case 10:
            codec = .aac
            if data.count < 2 { return }
            if data[data.startIndex + 1] == 0 {
                config = FLVReader.tail(data, from: 2)
            } else {
                payload = FLVReader.tail(data, from: 2)
            }
        case 2, 14:
            codec = .mp3
            payload = FLVReader.tail(data, from: 1)
        case 0, 3:
            codec = .pcm
            payload = FLVReader.tail(data, from: 1)
        case 9:
            // 拡張 RTMP の音声：下位 4 ビットがパケットの種類、そのあと FourCC
            if data.count < 5 { return }
            let packetType: UInt8 = first & 0x0F
            let fourCC: String = String(decoding: data.subdata(in: (data.startIndex + 1)..<(data.startIndex + 5)), as: UTF8.self)
            name = fourCC
            switch fourCC {
            case "mp4a": codec = .aac
            case ".mp3": codec = .mp3
            case "Opus": codec = .opus
            case "fLaC": codec = .flac
            case "ac-3": codec = .ac3
            case "ec-3": codec = .eac3
            default: codec = .unknown
            }
            if packetType == 0 {
                config = FLVReader.tail(data, from: 5)
            } else if packetType == 1 {
                payload = FLVReader.tail(data, from: 5)
            } else {
                return
            }
        case 1: name = "ADPCM"
        case 4, 5, 6: name = "Nellymoser"
        case 7: name = "G.711 A-law"
        case 8: name = "G.711 μ-law"
        case 11: name = "Speex"
        default: name = "音声の番号 \(format)"
        }
        if codec == .unknown && payload == nil && config == nil { payload = FLVReader.tail(data, from: 1) }
        if audio == nil {
            var track = ForeignTrack(number: FLVReader.audioNumber, kind: .audio, codec: codec, codecName: name)
            track.sampleRate = format == 2 || format == 14 ? 0 : rate
            if format == 14 { track.sampleRate = 8_000 }
            track.channels = stereo ? 2 : 1
            track.bitsPerSample = sixteen ? 16 : 8
            if codec == .opus { track.sampleRate = 48_000 }
            audio = track
        }
        if let made = config {
            audio?.codecPrivate = made
            if codec == .opus, made.count >= 12 {
                audio?.channels = Int(made[made.startIndex + 9])
                audio?.codecDelay = Double(Bytes.littleEndian(made, 10, 2)) / 48_000
            }
            return
        }
        guard let frame = payload, !frame.isEmpty else { return }
        sawAudioFrame = true
        queue.append(ForeignPacket(track: FLVReader.audioNumber, time: Double(tag.time) / 1000, duration: 0, keyframe: true, data: frame))
    }

    // MARK: 長さ

    /// onMetaData の "duration"（AMF0 の数値）。
    static func metadataDuration(_ data: Data) -> Double {
        let bytes: [UInt8] = [UInt8](data)
        let key: [UInt8] = [0x00, 0x08] + [UInt8]("duration".utf8)
        guard bytes.count >= key.count + 9 else { return 0 }
        for i in 0...(bytes.count - key.count - 9) where bytes[i] == 0x00 && bytes[i + 1] == 0x08 {
            if Array(bytes[i..<(i + key.count)]) != key { continue }
            let type: Int = i + key.count
            if bytes[type] != 0x00 { continue }
            let value: Double = Bytes.float(Data(bytes[(type + 1)..<(type + 9)]))
            return value.isFinite && value > 0 ? value : 0
        }
        return 0
    }

    /// 最後のタグの時刻（読み進める位置は元に戻す）。
    private func lastTagTime() -> Double {
        let saved: Int64 = reader.position
        defer { reader.seek(to: saved) }
        guard reader.size > 15 else { return 0 }
        reader.seek(to: reader.size - 4)
        guard let sizeData = try? reader.read(4), sizeData.count == 4 else { return 0 }
        let previous: Int64 = Int64(Bytes.bigEndian(sizeData))
        let start: Int64 = reader.size - 4 - previous
        guard previous >= 11, start >= 9 else { return 0 }
        reader.seek(to: start)
        guard let head = try? reader.read(11), head.count == 11 else { return 0 }
        let b: [UInt8] = [UInt8](head)
        let low: Int = (Int(b[4]) << 16) | (Int(b[5]) << 8) | Int(b[6])
        return Double(low | (Int(b[7]) << 24)) / 1000
    }
}
