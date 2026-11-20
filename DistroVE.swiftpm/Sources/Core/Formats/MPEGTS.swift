import Foundation

/// MPEG-TS の読み手（Q71）。ビデオカメラの AVCHD（.mts・.m2ts）、録画の .ts など。
/// 188 バイトのパケット（.ts）と、前に 4 バイトの時刻が付いた 192 バイトのパケット（.m2ts）の両方を読む。
/// PAT → PMT でトラックを決め、PES をつないでパケットにする。時刻は PES の PTS（90kHz）を最初からの秒にする。
/// 映像は H.264・HEVC（開始コードつきのまま）・MPEG-2、音声は AAC（ADTS）・AC-3・E-AC-3・MP2・MP3。
final class TSReader: ForeignDemuxer {
    private let reader: ByteReader
    private let packetSize: Int
    private let lead: Int
    private(set) var tracks: [ForeignTrack] = []
    private(set) var duration: Double = 0
    var containerName: String { return packetSize == 192 ? "M2TS" : "MPEG-TS" }

    private struct Assembly {
        var data: Data = Data()
        var pts: Int64?
    }

    private var assemblies: [Int: Assembly] = [:]
    private var kinds: [Int: ForeignTrack] = [:]
    private var queue: [ForeignPacket] = []
    private var finished: Bool = false
    private var origin: Int64?
    private var lastPTS: Int64 = 0

    init(_ reader: ByteReader) throws {
        self.reader = reader
        let head: [UInt8] = [UInt8](try reader.peek(192 * 3 + 4))
        if TSReader.looksLike(head, size: 188, lead: 0) {
            packetSize = 188
            lead = 0
        } else if TSReader.looksLike(head, size: 192, lead: 4) {
            packetSize = 192
            lead = 4
        } else {
            throw ForeignMediaError.notRecognized
        }
        try findTracks()
        if tracks.isEmpty { throw ForeignMediaError.broken("MPEG-TS に映像も音声もありません") }
        for track in tracks {
            kinds[track.number] = track
        }
        let range: (first: Int64, last: Int64)? = timeRange()
        origin = range?.first
        lastPTS = range?.first ?? 0
        duration = range.map { Double($0.last - $0.first) / 90_000 } ?? 0
        reader.seek(to: 0)
    }

    static func looksLike(_ head: [UInt8], size: Int, lead: Int) -> Bool {
        for i in 0..<3 {
            let at: Int = lead + i * size
            if at >= head.count || head[at] != 0x47 { return false }
        }
        return true
    }

    // MARK: パケット

    private struct Packet {
        let pid: Int
        let start: Bool
        let payload: Data
    }

    /// TS のパケットを 1 つ読む（同期が外れていたら 0x47 を探し直す）。
    private func readPacket() throws -> Packet? {
        while true {
            let raw: Data = try reader.read(packetSize)
            if raw.count < packetSize { return nil }
            let bytes: [UInt8] = [UInt8](raw)
            if bytes[lead] != 0x47 {
                reader.seek(to: reader.position - Int64(packetSize) + 1)
                continue
            }
            let b1: Int = Int(bytes[lead + 1])
            let b2: Int = Int(bytes[lead + 2])
            let b3: Int = Int(bytes[lead + 3])
            let pid: Int = ((b1 & 0x1F) << 8) | b2
            let start: Bool = b1 & 0x40 != 0
            let control: Int = (b3 >> 4) & 0x3
            var offset: Int = lead + 4
            if control == 2 || control == 0 { return Packet(pid: pid, start: start, payload: Data()) }
            if control == 3 {
                offset += 1 + Int(bytes[lead + 4])
            }
            if offset >= bytes.count { return Packet(pid: pid, start: start, payload: Data()) }
            return Packet(pid: pid, start: start, payload: Data(bytes[offset...]))
        }
    }

    // MARK: PAT・PMT

    private func findTracks() throws {
        var pmtPID: Int?
        var scanned: Int = 0
        var sections: [Int: Data] = [:]
        while scanned < 40_000, let packet = try readPacket() {
            scanned += 1
            if packet.pid == 0 && pmtPID == nil, let section = TSReader.section(packet, &sections) {
                pmtPID = TSReader.programMap(section)
            } else if let pid = pmtPID, packet.pid == pid, let section = TSReader.section(packet, &sections) {
                tracks = TSReader.streams(section)
                break
            }
        }
        // MPEG-2 は大きさを最初の sequence header から、MPEG 音声は Layer II（MP2）か III（MP3）かを最初のフレームから読む
        var waiting: Set<Int> = Set(tracks.filter { $0.codec == .mpeg2 || $0.codecName == "mpeg-audio" }.map { $0.number })
        if waiting.isEmpty { return }
        reader.seek(to: 0)
        scanned = 0
        while !waiting.isEmpty && scanned < 20_000, let packet = try readPacket() {
            scanned += 1
            guard waiting.contains(packet.pid), let index = tracks.firstIndex(where: { $0.number == packet.pid }) else { continue }
            if tracks[index].codec == .mpeg2 {
                if let size = TSReader.mpeg2Size(packet.payload) {
                    tracks[index].width = size.width
                    tracks[index].height = size.height
                    waiting.remove(packet.pid)
                }
            } else if packet.start, let header = TSReader.pesHeader(packet.payload), header.payload + 2 <= packet.payload.count {
                let at: Int = packet.payload.startIndex + header.payload
                let second: UInt8 = packet.payload[at + 1]
                tracks[index].codec = (second >> 1) & 0x3 == 1 ? .mp3 : .mp2
                waiting.remove(packet.pid)
            }
        }
    }

    /// PSI の区切り（pointer_field のあとの表）。1 パケットに収まる表だけを読む（PAT・PMT はふつう収まる）。
    private static func section(_ packet: Packet, _ partial: inout [Int: Data]) -> Data? {
        guard packet.start, let pointer = packet.payload.first else { return nil }
        let start: Int = 1 + Int(pointer)
        guard start + 3 <= packet.payload.count else { return nil }
        let bytes: [UInt8] = [UInt8](packet.payload)
        let length: Int = ((Int(bytes[start + 1]) & 0x0F) << 8) | Int(bytes[start + 2])
        guard start + 3 + length <= bytes.count else { return nil }
        return Data(bytes[start..<(start + 3 + length)])
    }

    /// PAT から最初の番組の PMT の PID。
    static func programMap(_ section: Data) -> Int? {
        let bytes: [UInt8] = [UInt8](section)
        guard bytes.count >= 12, bytes[0] == 0x00 else { return nil }
        let length: Int = ((Int(bytes[1]) & 0x0F) << 8) | Int(bytes[2])
        let end: Int = min(bytes.count, 3 + length - 4)
        var i: Int = 8
        while i + 4 <= end {
            let program: Int = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            let pid: Int = ((Int(bytes[i + 2]) & 0x1F) << 8) | Int(bytes[i + 3])
            if program != 0 { return pid }
            i += 4
        }
        return nil
    }

    /// PMT のストリームの一覧をトラックにする。
    static func streams(_ section: Data) -> [ForeignTrack] {
        let bytes: [UInt8] = [UInt8](section)
        guard bytes.count >= 16, bytes[0] == 0x02 else { return [] }
        let length: Int = ((Int(bytes[1]) & 0x0F) << 8) | Int(bytes[2])
        let end: Int = min(bytes.count, 3 + length - 4)
        let programInfo: Int = ((Int(bytes[10]) & 0x0F) << 8) | Int(bytes[11])
        var i: Int = 12 + programInfo
        var result: [ForeignTrack] = []
        var sawVideo: Bool = false
        var sawAudio: Bool = false
        while i + 5 <= end {
            let type: Int = Int(bytes[i])
            let pid: Int = ((Int(bytes[i + 1]) & 0x1F) << 8) | Int(bytes[i + 2])
            let infoLength: Int = ((Int(bytes[i + 3]) & 0x0F) << 8) | Int(bytes[i + 4])
            let infoEnd: Int = min(end, i + 5 + infoLength)
            let descriptors: [UInt8] = Array(bytes[min(i + 5, infoEnd)..<infoEnd])
            if let made = TSReader.track(pid: pid, type: type, descriptors: descriptors) {
                var track: ForeignTrack = made
                if track.kind == .video {
                    track.isDefault = !sawVideo
                    sawVideo = true
                } else if track.kind == .audio {
                    track.isDefault = !sawAudio
                    sawAudio = true
                }
                result.append(track)
            }
            i = infoEnd
        }
        return result
    }

    /// stream_type と記述子から、トラックの種類。
    static func track(pid: Int, type: Int, descriptors: [UInt8]) -> ForeignTrack? {
        var codec: ForeignCodec = .unknown
        var kind: ForeignTrackKind = .audio
        var name: String = String(format: "stream_type 0x%02X", type)
        var language: String = ""
        var registration: String = ""
        var tags: [Int] = []
        var d: Int = 0
        while d + 2 <= descriptors.count {
            let tag: Int = Int(descriptors[d])
            let length: Int = Int(descriptors[d + 1])
            let body: Int = d + 2
            tags.append(tag)
            if tag == 0x05 && body + 4 <= descriptors.count {
                registration = String(decoding: descriptors[body..<(body + 4)], as: UTF8.self)
            }
            if tag == 0x0A && body + 3 <= descriptors.count {
                language = String(decoding: descriptors[body..<(body + 3)], as: UTF8.self)
            }
            d = body + length
        }
        switch type {
        case 0x01, 0x02:
            codec = .mpeg2
            kind = .video
        case 0x1B:
            codec = .h264
            kind = .video
        case 0x24:
            codec = .hevc
            kind = .video
        case 0x03, 0x04:
            codec = .mp3
            name = "mpeg-audio"
        case 0x0F:
            codec = .aac
            name = "adts"
        case 0x11:
            name = "AAC（LATM）"
        case 0x81:
            codec = .ac3
        case 0x87:
            codec = .eac3
        case 0x82, 0x85, 0x86:
            codec = .dts
        case 0x80:
            name = "LPCM（Blu-ray）"
        case 0x06:
            if tags.contains(0x6A) || registration == "AC-3" {
                codec = .ac3
            } else if tags.contains(0x7A) || registration == "EAC3" {
                codec = .eac3
            } else if tags.contains(0x7B) || registration.hasPrefix("DTS") {
                codec = .dts
            } else if registration == "HEVC" {
                codec = .hevc
                kind = .video
            } else {
                return nil
            }
        default:
            return nil
        }
        var track = ForeignTrack(number: pid, kind: kind, codec: codec, codecName: name)
        track.language = language
        return track
    }

    /// MPEG-2 の sequence header（00 00 01 B3）の幅・高さ。
    static func mpeg2Size(_ data: Data) -> (width: Int, height: Int)? {
        let bytes: [UInt8] = [UInt8](data)
        if bytes.count < 8 { return nil }
        for i in 0..<(bytes.count - 7) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && bytes[i + 3] == 0xB3 {
            let a: Int = Int(bytes[i + 4])
            let b: Int = Int(bytes[i + 5])
            let c: Int = Int(bytes[i + 6])
            let width: Int = (a << 4) | (b >> 4)
            let height: Int = ((b & 0x0F) << 8) | c
            if width > 0 && height > 0 { return (width, height) }
        }
        return nil
    }

    // MARK: PES

    func nextPacket() throws -> ForeignPacket? {
        while queue.isEmpty && !finished {
            guard let packet = try readPacket() else {
                finished = true
                for pid in assemblies.keys.sorted() {
                    flush(pid)
                }
                break
            }
            guard kinds[packet.pid] != nil else { continue }
            if packet.start {
                flush(packet.pid)
                var assembly = Assembly()
                let parsed: (payload: Int, pts: Int64?)? = TSReader.pesHeader(packet.payload)
                if let header = parsed {
                    assembly.pts = header.pts
                    if header.payload < packet.payload.count {
                        assembly.data.append(packet.payload.subdata(in: (packet.payload.startIndex + header.payload)..<packet.payload.endIndex))
                    }
                    assemblies[packet.pid] = assembly
                }
            } else if assemblies[packet.pid] != nil {
                assemblies[packet.pid]?.data.append(packet.payload)
            }
        }
        if queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    /// PES の見出し（00 00 01・stream_id・長さ・フラグ）。中身の始まりと PTS。
    static func pesHeader(_ payload: Data) -> (payload: Int, pts: Int64?)? {
        let bytes: [UInt8] = [UInt8](payload.prefix(32))
        guard bytes.count >= 9, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 else { return nil }
        let streamID: Int = Int(bytes[3])
        let plain: Set<Int> = [0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xFF, 0xF2, 0xF8]
        if plain.contains(streamID) { return (6, nil) }
        let flags: Int = Int(bytes[7]) >> 6
        let headerLength: Int = Int(bytes[8])
        var pts: Int64?
        if flags & 0x2 != 0 && bytes.count >= 14 {
            pts = TSReader.timestamp(bytes, 9)
        }
        return (9 + headerLength, pts)
    }

    /// 33 ビットの時刻（5 バイト）。
    static func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        let p0: Int64 = Int64((b[i] >> 1) & 0x07)
        let p1: Int64 = Int64(b[i + 1])
        let p2: Int64 = Int64(b[i + 2] >> 1)
        let p3: Int64 = Int64(b[i + 3])
        let p4: Int64 = Int64(b[i + 4] >> 1)
        return (p0 << 30) | (p1 << 22) | (p2 << 15) | (p3 << 7) | p4
    }

    private func flush(_ pid: Int) {
        guard let assembly = assemblies.removeValue(forKey: pid), !assembly.data.isEmpty, let track = kinds[pid] else { return }
        var time: Double = 0
        if var pts = assembly.pts {
            // 33 ビットで一周したとき
            let wrap: Int64 = Int64(1) << 33
            if origin == nil { origin = pts }
            while pts + (wrap >> 1) < (origin ?? pts) { pts += wrap }
            lastPTS = max(lastPTS, pts)
            time = max(0, Double(pts - (origin ?? pts)) / 90_000)
        } else if let previous = queue.last(where: { $0.track == pid }) {
            time = previous.time
        }
        let keyframe: Bool = track.kind == .video ? TSReader.isKeyframe(assembly.data, track.codec) : true
        queue.append(ForeignPacket(track: pid, time: time, duration: 0, keyframe: keyframe, data: assembly.data))
    }

    /// キーフレームか（H.264 の IDR、HEVC の IRAP、MPEG-2 の I ピクチャー）。
    static func isKeyframe(_ data: Data, _ codec: ForeignCodec) -> Bool {
        let bytes: [UInt8] = [UInt8](data.prefix(4096))
        if bytes.count < 5 { return false }
        for i in 0..<(bytes.count - 4) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
            let header: Int = Int(bytes[i + 3])
            switch codec {
            case .h264:
                if header & 0x1F == 5 { return true }
            case .hevc:
                let type: Int = (header >> 1) & 0x3F
                if type >= 16 && type <= 21 { return true }
            case .mpeg2:
                if header == 0x00 && i + 5 < bytes.count {
                    return (Int(bytes[i + 5]) >> 3) & 0x7 == 1
                }
            default:
                return true
            }
        }
        return false
    }

    // MARK: 長さ

    /// 最初（最初の数百の PES で一番早いもの。B フレームがあっても 0 秒より前にならないように）と最後の PTS。
    private func timeRange() -> (first: Int64, last: Int64)? {
        let saved: Int64 = reader.position
        defer { reader.seek(to: saved) }
        var first: Int64?
        var seen: Int = 0
        var count: Int = 0
        reader.seek(to: 0)
        while seen < 400 && count < 60_000, let packet = try? readPacket() {
            count += 1
            if packet.start && kinds[packet.pid] != nil, let header = TSReader.pesHeader(packet.payload), let pts = header.pts {
                first = min(first ?? pts, pts)
                seen += 1
            }
        }
        guard let start = first else { return nil }
        let window: Int64 = min(reader.size, Int64(2 * 1024 * 1024))
        let aligned: Int64 = ((reader.size - window) / Int64(packetSize)) * Int64(packetSize)
        reader.seek(to: aligned)
        var last: Int64 = start
        while let packet = try? readPacket() {
            if packet.start && kinds[packet.pid] != nil, let header = TSReader.pesHeader(packet.payload), var pts = header.pts {
                let wrap: Int64 = Int64(1) << 33
                while pts + (wrap >> 1) < start { pts += wrap }
                last = max(last, pts)
            }
        }
        return (start, last)
    }
}
