#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// MKV・WebM・AVI の音声を、端末の仕組みで読める 1 本のファイルに書き出す（Q71）。
/// AAC は ADTS、MP3・MP2・AC-3・E-AC-3 はそのまま並べ、FLAC はネイティブの FLAC、PCM は WAV にする。
/// Opus は AudioToolbox で解読して WAV にする。Vorbis・DTS は読めない。
final class ForeignAudioExtractor {
    enum Mode {
        case adts(profile: Int, index: Int, channels: Int)
        case raw
        case flac
        case wav(bits: Int, float: Bool, bigEndian: Bool)
        case opus
    }

    let track: ForeignTrack
    let url: URL
    private let mode: Mode
    private let handle: FileHandle
    private var dataBytes: Int64 = 0
    private var opus: OpusDecoder?
    private(set) var firstTime: Double?

    init(track: ForeignTrack, folder: URL) throws {
        self.track = track
        let made: (Mode, String) = try ForeignAudioExtractor.mode(for: track)
        mode = made.0
        url = folder.appendingPathComponent("audio." + made.1)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        switch mode {
        case .flac:
            try handle.write(contentsOf: ForeignAudioExtractor.flacHeader(track.codecPrivate))
        case .wav:
            try handle.write(contentsOf: Data(count: 44))
        case .opus:
            opus = try OpusDecoder(track: track)
            try handle.write(contentsOf: Data(count: 44))
        case .adts, .raw:
            break
        }
    }

    deinit {
        try? handle.close()
    }

    static func mode(for track: ForeignTrack) throws -> (Mode, String) {
        switch track.codec {
        case .aac:
            if track.codecName == "0x1610" { return (.raw, "aac") }
            guard let p = ForeignAudioExtractor.adtsParameters(track.codecPrivate, sampleRate: track.sampleRate, channels: track.channels) else {
                throw EngineError.unsupported("AAC の設定が見つかりません")
            }
            return (.adts(profile: p.profile, index: p.index, channels: p.channels), "aac")
        case .mp3: return (.raw, "mp3")
        case .mp2: return (.raw, "mp2")
        case .ac3: return (.raw, "ac3")
        case .eac3: return (.raw, "ec3")
        case .flac: return (.flac, "flac")
        case .pcm:
            let bits: Int = track.bitsPerSample > 0 ? track.bitsPerSample : 16
            return (.wav(bits: bits, float: track.floatSamples, bigEndian: track.bigEndian), "wav")
        case .opus:
            if track.channels > 2 { throw EngineError.unsupported("3 チャンネル以上の Opus は読めません") }
            return (.opus, "wav")
        default:
            throw EngineError.unsupported("音声（\(track.codec.label)）はこの端末では読めません")
        }
    }

    func append(_ packet: ForeignPacket) throws {
        if firstTime == nil { firstTime = packet.time }
        switch mode {
        case .adts(let profile, let index, let channels):
            try handle.write(contentsOf: ForeignAudioExtractor.adtsHeader(profile: profile, index: index, channels: channels, payload: packet.data.count))
            try handle.write(contentsOf: packet.data)
        case .raw, .flac:
            try handle.write(contentsOf: packet.data)
        case .wav(let bits, _, let bigEndian):
            let samples: Data = bigEndian ? ForeignAudioExtractor.swapped(packet.data, bytesPerSample: max(1, bits / 8)) : packet.data
            try handle.write(contentsOf: samples)
            dataBytes += Int64(samples.count)
        case .opus:
            guard let decoder = opus else { return }
            let pcm: Data = try decoder.decode(packet.data)
            try handle.write(contentsOf: pcm)
            dataBytes += Int64(pcm.count)
        }
    }

    /// 書き終える。WAV は大きさを頭に書き戻す。
    func finish() throws -> URL {
        switch mode {
        case .wav(let bits, let float, _):
            let header: Data = ForeignAudioExtractor.wavHeader(dataBytes: dataBytes, sampleRate: Int(track.sampleRate),
                                                             channels: max(1, track.channels), bits: bits, float: float)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header)
        case .opus:
            let header: Data = ForeignAudioExtractor.wavHeader(dataBytes: dataBytes, sampleRate: 48_000,
                                                             channels: max(1, track.channels), bits: 32, float: true)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header)
        case .adts, .raw, .flac:
            break
        }
        try handle.close()
        return url
    }

    // MARK: AAC（ADTS）

    static let sampleRates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// AudioSpecificConfig から、ADTS の profile・周波数の番号・チャンネル数。
    static func adtsParameters(_ asc: Data, sampleRate: Double, channels: Int) -> (profile: Int, index: Int, channels: Int)? {
        let fallbackIndex: Int = sampleRates.firstIndex(where: { abs($0 - sampleRate) < 1 }) ?? 3
        if asc.count < 2 {
            return channels > 0 ? (1, fallbackIndex, min(7, channels)) : nil
        }
        let b0: Int = Int(asc[asc.startIndex])
        let b1: Int = Int(asc[asc.startIndex + 1])
        let objectType: Int = b0 >> 3
        var index: Int = ((b0 & 0x07) << 1) | (b1 >> 7)
        var channelConfig: Int = (b1 >> 3) & 0x0F
        if index == 15 {
            index = fallbackIndex
            channelConfig = min(7, max(1, channels))
        }
        // HE-AAC（SBR・PS）の土台は AAC LC。ADTS の profile は「種類 - 1」
        let profile: Int = (objectType == 5 || objectType == 29 || objectType == 31 || objectType == 0) ? 1 : min(3, objectType - 1)
        if channelConfig == 0 { channelConfig = min(7, max(1, channels)) }
        return (profile, index, channelConfig)
    }

    /// ADTS の 7 バイトの見出し。式を細かく分けて型を書く（まとめて書くと Xcode 16 の型の確認が終わらない）。
    static func adtsHeader(profile: Int, index: Int, channels: Int, payload: Int) -> Data {
        let length: Int = payload + 7
        let p: Int = (profile & 0x3) << 6
        let i: Int = (index & 0xF) << 2
        let c: Int = (channels >> 2) & 0x1
        let c2: Int = (channels & 0x3) << 6
        let l1: Int = (length >> 11) & 0x3
        let l2: Int = (length >> 3) & 0xFF
        let l3: Int = (length & 0x7) << 5
        var header: [UInt8] = [0xFF, 0xF1]
        header.append(UInt8(truncatingIfNeeded: p | i | c))
        header.append(UInt8(truncatingIfNeeded: c2 | l1))
        header.append(UInt8(truncatingIfNeeded: l2))
        header.append(UInt8(truncatingIfNeeded: l3 | 0x1F))
        header.append(0xFC)
        return Data(header)
    }

    // MARK: FLAC

    /// "fLaC" とメタデータ。最後のブロックには「最後」の印を付ける。
    static func flacHeader(_ codecPrivate: Data) -> Data {
        var data: Data = codecPrivate
        if data.prefix(4) != Data("fLaC".utf8) {
            var fixed = Data("fLaC".utf8)
            fixed.append(contentsOf: [0x80, 0x00, 0x00, UInt8(min(255, data.count))])
            fixed.append(data)
            return fixed
        }
        var offset: Int = 4
        var lastHeader: Int = -1
        while offset + 4 <= data.count {
            lastHeader = offset
            let base: Int = data.startIndex + offset
            let size: Int = Int(data[base + 1]) << 16 | Int(data[base + 2]) << 8 | Int(data[base + 3])
            if data[base] & 0x80 != 0 { break }
            offset += 4 + size
        }
        if lastHeader >= 0 {
            let base: Int = data.startIndex + lastHeader
            data[base] = data[base] | 0x80
        }
        return data
    }

    // MARK: WAV

    static func wavHeader(dataBytes: Int64, sampleRate: Int, channels: Int, bits: Int, float: Bool) -> Data {
        let blockAlign: Int = channels * max(1, bits / 8)
        let byteRate: Int = sampleRate * blockAlign
        var d = Data("RIFF".utf8)
        d.append(ForeignAudioExtractor.le32(Int(min(Int64(UInt32.max), 36 + dataBytes))))
        d.append(Data("WAVEfmt ".utf8))
        d.append(ForeignAudioExtractor.le32(16))
        d.append(ForeignAudioExtractor.le16(float ? 3 : 1))
        d.append(ForeignAudioExtractor.le16(channels))
        d.append(ForeignAudioExtractor.le32(sampleRate))
        d.append(ForeignAudioExtractor.le32(byteRate))
        d.append(ForeignAudioExtractor.le16(blockAlign))
        d.append(ForeignAudioExtractor.le16(bits))
        d.append(Data("data".utf8))
        d.append(ForeignAudioExtractor.le32(Int(min(Int64(UInt32.max), dataBytes))))
        return d
    }

    static func le16(_ v: Int) -> Data {
        return Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }

    static func le32(_ v: Int) -> Data {
        return Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }

    /// ビッグエンディアンの PCM をリトルエンディアンに直す。
    static func swapped(_ data: Data, bytesPerSample: Int) -> Data {
        if bytesPerSample <= 1 { return data }
        var bytes: [UInt8] = [UInt8](data)
        var i: Int = 0
        while i + bytesPerSample <= bytes.count {
            bytes[i..<(i + bytesPerSample)].reverse()
            i += bytesPerSample
        }
        return Data(bytes)
    }
}

/// Opus を AudioToolbox で解読する（48kHz・2 チャンネルまで）。最初の前置き（pre-skip）は捨てる。
final class OpusDecoder {
    private let converter: AVAudioConverter
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private var skip: Int

    init(track: ForeignTrack) throws {
        let channels: Int = max(1, min(2, track.channels))
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                                      mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
                                                      mBitsPerChannel: 0, mReserved: 0)
        guard let source = AVAudioFormat(streamDescription: &description),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true),
              let made = AVAudioConverter(from: source, to: target) else {
            throw EngineError.unsupported("音声（Opus）はこの端末では読めません")
        }
        input = source
        output = target
        converter = made
        skip = OpusDecoder.preSkip(track.codecPrivate)
    }

    /// OpusHead の pre-skip（48kHz のサンプル数）。
    static func preSkip(_ head: Data) -> Int {
        if head.count < 12 || head.prefix(8) != Data("OpusHead".utf8) { return 0 }
        return Int(Bytes.littleEndian(head, 10, 2))
    }

    /// パケットの TOC から、このパケットのサンプル数（48kHz）。
    static func frames(_ packet: Data) -> Int {
        guard let toc = packet.first else { return 960 }
        let config: Int = Int(toc >> 3)
        let size: Int
        if config < 12 {
            size = [480, 960, 1920, 2880][config % 4]
        } else if config < 16 {
            size = [480, 960][config % 2]
        } else {
            size = [120, 240, 480, 960][config % 4]
        }
        let code: UInt8 = toc & 0x3
        var count: Int = 1
        if code == 1 || code == 2 {
            count = 2
        } else if code == 3 && packet.count > 1 {
            count = Int(packet[packet.startIndex + 1] & 0x3F)
        }
        return size * max(1, count)
    }

    /// 1 パケットを解読して、リトルエンディアンの 32bit 浮動小数（チャンネル交互）にする。
    func decode(_ packet: Data) throws -> Data {
        if packet.isEmpty { return Data() }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            if let base = raw.baseAddress { compressed.data.copyMemory(from: base, byteCount: packet.count) }
        }
        let frameCount: Int = OpusDecoder.frames(packet)
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: UInt32(frameCount),
                                                                              mDataByteSize: UInt32(packet.count))
        compressed.packetCount = 1
        compressed.byteLength = UInt32(packet.count)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(max(5760, frameCount))) else { return Data() }
        var supplied: Bool = false
        var error: NSError?
        let status: AVAudioConverterOutputStatus = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return compressed
        }
        if status == .error { throw EngineError.unsupported(error?.localizedDescription ?? "Opus を解読できません") }
        return trimmed(pcm)
    }

    private func trimmed(_ pcm: AVAudioPCMBuffer) -> Data {
        guard let samples = pcm.floatChannelData?[0] else { return Data() }
        let channels: Int = Int(output.channelCount)
        var frames: Int = Int(pcm.frameLength)
        var start: Int = 0
        if skip > 0 {
            let dropped: Int = min(skip, frames)
            skip -= dropped
            start = dropped
            frames -= dropped
        }
        if frames <= 0 { return Data() }
        let pointer: UnsafePointer<Float> = UnsafePointer(samples.advanced(by: start * channels))
        return Data(bytes: pointer, count: frames * channels * MemoryLayout<Float>.size)
    }
}
#endif
