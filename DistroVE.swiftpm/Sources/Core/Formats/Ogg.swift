import Foundation

/// Ogg（.ogg・.oga・.opus・.ogv）の読み手（Q71）。中の Vorbis・Opus・FLAC を取り出す。
/// ページ（"OggS"）をつないでパケットにする。見出しのパケットは CodecPrivate にまとめ、音声のパケットだけを返す。
/// Theora の映像は解読できないため、トラックとして見せて「読めない」と伝える。
final class OggReader: ForeignDemuxer {
    private let reader: ByteReader
    private(set) var tracks: [ForeignTrack] = []
    private(set) var duration: Double = 0
    var containerName: String { return "Ogg" }

    private struct Stream {
        var track: ForeignTrack
        /// 残りの見出しのパケット数（-1 は FLAC の「数が書かれていない」）
        var headersLeft: Int
        var headers: [Data] = []
        var pending: Data = Data()
        /// 直前のページの位置（サンプル数）
        var granule: Int64 = 0
        var rate: Double
        var preSkip: Int64 = 0
    }

    private var streams: [UInt32: Stream] = [:]
    private var order: [UInt32] = []
    private var queue: [ForeignPacket] = []
    private var finished: Bool = false

    init(_ reader: ByteReader) throws {
        self.reader = reader
        // 見出しが全部そろうまでページを読む（そのあとに来た音声のパケットは queue に入る）
        while !finished && (streams.isEmpty || streams.values.contains { $0.headersLeft != 0 }) {
            if try !readPage() { break }
        }
        if streams.isEmpty { throw ForeignMediaError.broken("Ogg の中身がありません") }
        for serial in order {
            guard var stream = streams[serial] else { continue }
            stream.track.codecPrivate = OggReader.codecPrivate(stream.track.codec, stream.headers)
            streams[serial] = stream
            tracks.append(stream.track)
        }
        duration = lastTime()
    }

    func nextPacket() throws -> ForeignPacket? {
        while queue.isEmpty && !finished {
            if try !readPage() { break }
        }
        if queue.isEmpty { return nil }
        return queue.removeFirst()
    }

    // MARK: ページ

    /// ページを 1 つ読む。終わりなら false。
    private func readPage() throws -> Bool {
        guard try sync() else {
            finished = true
            return false
        }
        let header: Data = try reader.read(27)
        if header.count < 27 {
            finished = true
            return false
        }
        let flags: UInt8 = header[header.startIndex + 5]
        let granule: Int64 = Int64(bitPattern: Bytes.littleEndian(header, 6, 8))
        let serial: UInt32 = UInt32(truncatingIfNeeded: Bytes.littleEndian(header, 14, 4))
        let count: Int = Int(header[header.startIndex + 26])
        let table: [UInt8] = [UInt8](try reader.read(count))
        let total: Int = table.reduce(0) { $0 + Int($1) }
        let body: Data = try reader.read(total)
        if body.count < total {
            finished = true
            return false
        }
        if flags & 0x02 != 0 && streams[serial] == nil {
            if let first = OggReader.firstPacket(body, table) {
                addStream(serial, first)
            }
        }
        guard var stream = streams[serial] else { return true }
        if flags & 0x01 == 0 { stream.pending = Data() }
        var offset: Int = body.startIndex
        let start: Double = max(0, Double(stream.granule - stream.preSkip)) / max(1, stream.rate)
        for size in table {
            let length: Int = Int(size)
            stream.pending.append(body[offset..<(offset + length)])
            offset += length
            if size < 255 {
                let packet: Data = stream.pending
                stream.pending = Data()
                deliver(packet, stream: &stream, time: start)
            }
        }
        if granule >= 0 { stream.granule = granule }
        streams[serial] = stream
        return true
    }

    /// 次の "OggS" まで進める（壊れた所を飛ばす）。
    private func sync() throws -> Bool {
        while !reader.isAtEnd {
            let head: Data = try reader.peek(4)
            if head.count < 4 { return false }
            if head == Data("OggS".utf8) { return true }
            reader.skip(1)
        }
        return false
    }

    private static func firstPacket(_ body: Data, _ table: [UInt8]) -> Data? {
        var length: Int = 0
        for size in table {
            length += Int(size)
            if size < 255 { break }
        }
        if length == 0 || length > body.count { return nil }
        return body.prefix(length)
    }

    /// 最初のパケットで中身の種類を見分けてトラックを作る。
    private func addStream(_ serial: UInt32, _ first: Data) {
        let bytes: [UInt8] = [UInt8](first.prefix(64))
        let number: Int = order.count + 1
        var track: ForeignTrack
        var headers: Int = 0
        var rate: Double = 0
        var preSkip: Int64 = 0
        if bytes.count >= 30 && bytes[0] == 1 && Data(bytes[1..<7]) == Data("vorbis".utf8) {
            track = ForeignTrack(number: number, kind: .audio, codec: .vorbis, codecName: "vorbis")
            track.channels = Int(bytes[11])
            rate = Double(Bytes.littleEndian(first, 12, 4))
            headers = 3
        } else if bytes.count >= 19 && Data(bytes[0..<8]) == Data("OpusHead".utf8) {
            track = ForeignTrack(number: number, kind: .audio, codec: .opus, codecName: "opus")
            track.channels = Int(bytes[9])
            preSkip = Int64(Bytes.littleEndian(first, 10, 2))
            track.codecDelay = Double(preSkip) / 48_000
            rate = 48_000
            headers = 2
        } else if bytes.count >= 51 && bytes[0] == 0x7F && Data(bytes[1..<5]) == Data("FLAC".utf8) {
            track = ForeignTrack(number: number, kind: .audio, codec: .flac, codecName: "flac")
            // 13 バイト目から "fLaC" と STREAMINFO（見出し 4 + 中身 34）
            let info: Int = 9 + 4 + 4
            let b10: Int = Int(bytes[info + 10])
            let b11: Int = Int(bytes[info + 11])
            let b12: Int = Int(bytes[info + 12])
            let b13: Int = Int(bytes[info + 13])
            let hertz: Int = (b10 << 12) | (b11 << 4) | (b12 >> 4)
            rate = Double(hertz)
            track.channels = ((b12 >> 1) & 0x7) + 1
            let bits: Int = ((b12 & 1) << 4) | (b13 >> 4)
            track.bitsPerSample = bits + 1
            let more: Int = (Int(bytes[7]) << 8) | Int(bytes[8])
            headers = more == 0 ? -1 : more + 1
        } else if bytes.count >= 7 && bytes[0] == 0x80 && Data(bytes[1..<7]) == Data("theora".utf8) {
            track = ForeignTrack(number: number, kind: .video, codec: .theora, codecName: "theora")
            if bytes.count >= 20 {
                track.width = (Int(bytes[14]) << 16) | (Int(bytes[15]) << 8) | Int(bytes[16])
                track.height = (Int(bytes[17]) << 16) | (Int(bytes[18]) << 8) | Int(bytes[19])
            }
            headers = 3
        } else {
            let name: String = String(decoding: bytes.prefix(8), as: UTF8.self).trimmingCharacters(in: .whitespaces)
            let isSpeex: Bool = name.hasPrefix("Speex")
            track = ForeignTrack(number: number, kind: isSpeex ? .audio : .other, codec: .unknown, codecName: name)
            headers = 0
        }
        track.sampleRate = rate
        streams[serial] = Stream(track: track, headersLeft: headers, rate: rate, preSkip: preSkip)
        order.append(serial)
    }

    /// 組み上がったパケットを、見出しなら取っておき、音声なら queue に入れる。
    private func deliver(_ packet: Data, stream: inout Stream, time: Double) {
        if stream.headersLeft > 0 {
            stream.headers.append(packet)
            stream.headersLeft -= 1
            return
        }
        if stream.headersLeft < 0 {
            // 数の書かれていない FLAC：音声のかたまりは 0xFF で始まる
            if let first = packet.first, first != 0xFF {
                stream.headers.append(packet)
                return
            }
            stream.headersLeft = 0
        }
        if packet.isEmpty || stream.track.codec == .unknown { return }
        queue.append(ForeignPacket(track: stream.track.number, time: time, duration: 0, keyframe: true, data: packet))
    }

    /// 見出しを、Matroska と同じ形の CodecPrivate にする。
    static func codecPrivate(_ codec: ForeignCodec, _ headers: [Data]) -> Data {
        switch codec {
        case .vorbis:
            guard headers.count >= 3 else { return Data() }
            var data = Data([2])
            for header in headers.prefix(2) {
                var size: Int = header.count
                while size >= 255 {
                    data.append(255)
                    size -= 255
                }
                data.append(UInt8(size))
            }
            for header in headers.prefix(3) {
                data.append(header)
            }
            return data
        case .opus:
            return headers.first ?? Data()
        case .flac:
            // 最初のパケットの 9 バイト目から "fLaC" と STREAMINFO、続くパケットがほかのメタデータ
            guard let first = headers.first, first.count > 9 else { return Data() }
            var data: Data = first.subdata(in: (first.startIndex + 9)..<first.endIndex)
            for header in headers.dropFirst() {
                data.append(header)
            }
            return data
        default:
            return headers.first ?? Data()
        }
    }

    // MARK: 長さ

    /// 最後の方のページの位置から長さを求める（読み進める位置は元に戻す）。
    private func lastTime() -> Double {
        let saved: Int64 = reader.position
        defer { reader.seek(to: saved) }
        let window: Int64 = min(reader.size, 256 * 1024)
        reader.seek(to: reader.size - window)
        guard let tail = try? reader.read(Int(window)) else { return 0 }
        let bytes: [UInt8] = [UInt8](tail)
        var best: Double = 0
        var i: Int = 0
        while i + 27 <= bytes.count {
            if bytes[i] == 0x4F && bytes[i + 1] == 0x67 && bytes[i + 2] == 0x67 && bytes[i + 3] == 0x53 {
                let page: Data = Data(bytes[i..<(i + 27)])
                let granule: Int64 = Int64(bitPattern: Bytes.littleEndian(page, 6, 8))
                let serial: UInt32 = UInt32(truncatingIfNeeded: Bytes.littleEndian(page, 14, 4))
                if let stream = streams[serial], stream.track.kind == .audio, granule > 0, stream.rate > 0 {
                    best = max(best, Double(granule - stream.preSkip) / stream.rate)
                }
                i += 27
            } else {
                i += 1
            }
        }
        return best
    }
}
