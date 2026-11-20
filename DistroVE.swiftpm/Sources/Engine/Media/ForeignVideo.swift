#if canImport(VideoToolbox) && canImport(AVFoundation)
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import VideoToolbox

/// MKV・WebM・AVI・FLV の映像を解読する（Q71）。
/// H.264・HEVC・MPEG-4・MPEG-2・VP9・AV1 は VideoToolbox、Motion JPEG は ImageIO、VP8 は自前の解読器（Core の VP8Decoder）を使う。
final class ForeignVideoDecoder {
    struct Frame {
        let image: CVPixelBuffer
        let time: Double
    }

    let track: ForeignTrack
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    /// AVI の H.264 / HEVC（開始コードつき）を長さつきに直す
    private var annexB: Bool = false
    /// 表示の順が分からない（AVI）ときは、解読器に並べ替えさせて時刻を振り直す
    private let reorderInDecoder: Bool
    private var nextOutputIndex: Int = 0
    private let collector = FrameCollector()
    private var jpegPool: CVPixelBufferPool?
    private var vp8: VP8Decoder?
    private var vp8Pool: CVPixelBufferPool?
    private var vp8Size: (width: Int, height: Int) = (0, 0)
    private var failures: Int = 0

    init(track: ForeignTrack, timesAreDecodeOrder: Bool) throws {
        self.track = track
        self.reorderInDecoder = timesAreDecodeOrder
        switch track.codec {
        case .mjpeg:
            return
        case .vp8:
            vp8 = VP8Decoder()
        case .h264, .hevc, .mpeg4, .mpeg2, .vp9, .av1:
            if !track.codecPrivate.isEmpty || track.codec == .mpeg2 || track.codec == .vp9 {
                try makeSession(firstFrame: nil)
            }
        default:
            throw EngineError.unsupported("映像（\(track.codecLabel)）はこの端末では読めません")
        }
    }

    /// 1 パケットを解読する。出てきたコマ（解読の順）を返す。
    func decode(_ packet: ForeignPacket) throws -> [Frame] {
        if track.codec == .mjpeg {
            guard let image = decodeJPEG(packet.data) else {
                failures += 1
                return []
            }
            return [Frame(image: image, time: packet.time)]
        }
        if let decoder = vp8 {
            do {
                // 表示しないフレーム（altref）は nil。時刻は次のフレームのものを使う
                guard let picture = try decoder.decode(packet.data) else { return [] }
                guard let image = vp8PixelBuffer(picture) else {
                    failures += 1
                    return []
                }
                return [Frame(image: image, time: packet.time)]
            } catch {
                failures += 1
                return []
            }
        }
        if session == nil {
            // 設定（SPS・PPS・VOL）が最初のキーフレームにしかないとき
            if !packet.keyframe { return [] }
            try makeSession(firstFrame: packet.data)
        }
        guard let session = session, let format = format else { return [] }
        let payload: Data = annexB ? ForeignVideoDecoder.lengthPrefixed(packet.data) : packet.data
        let pts = CMTime(seconds: packet.time, preferredTimescale: 90_000)
        let duration = CMTime(seconds: max(0.001, packet.duration), preferredTimescale: 90_000)
        guard let sample = ForeignVideoDecoder.sampleBuffer(payload, format: format, pts: pts, duration: duration) else { return [] }
        let flags: VTDecodeFrameFlags = reorderInDecoder ? [._EnableTemporalProcessing] : []
        let collector: FrameCollector = self.collector
        let status: OSStatus = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil) {
            (result: OSStatus, _: VTDecodeInfoFlags, image: CVImageBuffer?, time: CMTime, _: CMTime) in
            collector.add(result == noErr ? image : nil, time.seconds)
        }
        if status != noErr { failures += 1 }
        return takeFrames()
    }

    /// 残りのコマ（並べ替えのために持っていたもの）。
    func flush() -> [Frame] {
        if let session = session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        return takeFrames()
    }

    var failedFrames: Int { return failures + collector.failures }

    private func takeFrames() -> [Frame] {
        var frames: [Frame] = []
        for item in collector.take() {
            if reorderInDecoder {
                // 表示の順に出てくるので、時刻はコマの番号から振る
                let time: Double = Double(nextOutputIndex) * max(0.001, track.defaultDuration)
                nextOutputIndex += 1
                frames.append(Frame(image: item.0, time: time))
            } else {
                frames.append(Frame(image: item.0, time: item.1))
            }
        }
        return frames
    }

    deinit {
        if let session = session { VTDecompressionSessionInvalidate(session) }
    }

    // MARK: 解読の準備

    private func makeSession(firstFrame: Data?) throws {
        let description: CMVideoFormatDescription = try makeFormat(firstFrame: firstFrame)
        #if os(macOS)
        if track.codec == .vp9 { VTRegisterSupplementalVideoDecoderIfAvailable(ForeignVideoDecoder.vp9) }
        #endif
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
        var created: VTDecompressionSession?
        let status: OSStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description, decoderSpecification: nil,
                                                            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
                                                            decompressionSessionOut: &created)
        guard status == noErr, let made = created else {
            throw EngineError.unsupported("映像（\(track.codecLabel)）はこの端末では読めません")
        }
        format = description
        session = made
    }

    static let vp9: CMVideoCodecType = 0x7670_3039
    static let av1: CMVideoCodecType = 0x6176_3031

    private func makeFormat(firstFrame: Data?) throws -> CMVideoFormatDescription {
        let width: Int32 = Int32(max(2, track.width))
        let height: Int32 = Int32(max(2, track.height))
        let config: Data = track.codecPrivate
        switch track.codec {
        case .h264:
            if config.first == 1 && track.width < 16, let found = ForeignVideoDecoder.avcCSets(config) {
                // 大きさの分からない入れ物（FLV など）：SPS から大きさを求める
                return try ForeignVideoDecoder.h264Format(found.sets, lengthSize: found.lengthSize)
            }
            if config.first == 1 { return try ForeignVideoDecoder.withAtom("avcC", config, kCMVideoCodecType_H264, width, height) }
            annexB = true
            let sets: [Data] = ForeignVideoDecoder.parameterSets(firstFrame ?? config, h264: true)
            return try ForeignVideoDecoder.h264Format(sets)
        case .hevc:
            if config.first == 1 && track.width < 16, let found = ForeignVideoDecoder.hvcCSets(config) {
                return try ForeignVideoDecoder.hevcFormat(found.sets, lengthSize: found.lengthSize)
            }
            if config.first == 1 { return try ForeignVideoDecoder.withAtom("hvcC", config, kCMVideoCodecType_HEVC, width, height) }
            annexB = true
            let sets: [Data] = ForeignVideoDecoder.parameterSets(firstFrame ?? config, h264: false)
            return try ForeignVideoDecoder.hevcFormat(sets)
        case .mpeg4:
            let vol: Data = config.isEmpty ? ForeignVideoDecoder.mpeg4Headers(firstFrame ?? Data()) : config
            if vol.isEmpty { throw EngineError.unsupported("MPEG-4 の設定が見つかりません") }
            var box = Data([0, 0, 0, 0])
            box.append(ForeignVideoDecoder.esDescriptor(vol, objectType: 0x20, streamType: 0x04))
            return try ForeignVideoDecoder.withAtom("esds", box, kCMVideoCodecType_MPEG4Video, width, height)
        case .av1:
            return try ForeignVideoDecoder.withAtom("av1C", config, ForeignVideoDecoder.av1, width, height)
        case .vp9:
            return try ForeignVideoDecoder.withAtom("vpcC", ForeignVideoDecoder.vpcC(), ForeignVideoDecoder.vp9, width, height)
        case .mpeg2:
            return try ForeignVideoDecoder.plainFormat(kCMVideoCodecType_MPEG2Video, width, height)
        default:
            throw EngineError.unsupported("映像（\(track.codecLabel)）はこの端末では読めません")
        }
    }

    static func withAtom(_ name: String, _ data: Data, _ codec: CMVideoCodecType, _ width: Int32, _ height: Int32) throws -> CMVideoFormatDescription {
        var atoms: [String: Any] = [:]
        atoms[name] = data
        var extensions: [String: Any] = [:]
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] = atoms
        var result: CMVideoFormatDescription?
        let status: OSStatus = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec, width: width, height: height,
                                                              extensions: extensions as CFDictionary, formatDescriptionOut: &result)
        guard status == noErr, let made = result else { throw EngineError.unsupported("映像の設定を読めません") }
        return made
    }

    static func plainFormat(_ codec: CMVideoCodecType, _ width: Int32, _ height: Int32) throws -> CMVideoFormatDescription {
        var result: CMVideoFormatDescription?
        let status: OSStatus = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec, width: width, height: height,
                                                              extensions: nil, formatDescriptionOut: &result)
        guard status == noErr, let made = result else { throw EngineError.unsupported("映像の設定を読めません") }
        return made
    }

    /// avcC の中の SPS・PPS と、長さの欄のバイト数。
    static func avcCSets(_ config: Data) -> (sets: [Data], lengthSize: Int)? {
        let bytes: [UInt8] = [UInt8](config)
        if bytes.count < 7 { return nil }
        let lengthSize: Int = Int(bytes[4] & 0x3) + 1
        var sets: [Data] = []
        var i: Int = 5
        for group in 0..<2 {
            guard i < bytes.count else { break }
            let count: Int = group == 0 ? Int(bytes[i] & 0x1F) : Int(bytes[i])
            i += 1
            for _ in 0..<count {
                guard i + 2 <= bytes.count else { return nil }
                let length: Int = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
                i += 2
                guard i + length <= bytes.count else { return nil }
                sets.append(Data(bytes[i..<(i + length)]))
                i += length
            }
        }
        return sets.isEmpty ? nil : (sets, lengthSize)
    }

    /// hvcC の中の VPS・SPS・PPS と、長さの欄のバイト数。
    static func hvcCSets(_ config: Data) -> (sets: [Data], lengthSize: Int)? {
        let bytes: [UInt8] = [UInt8](config)
        if bytes.count < 23 { return nil }
        let lengthSize: Int = Int(bytes[21] & 0x3) + 1
        let arrays: Int = Int(bytes[22])
        var sets: [Data] = []
        var i: Int = 23
        for _ in 0..<arrays {
            guard i + 3 <= bytes.count else { return nil }
            let count: Int = (Int(bytes[i + 1]) << 8) | Int(bytes[i + 2])
            i += 3
            for _ in 0..<count {
                guard i + 2 <= bytes.count else { return nil }
                let length: Int = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
                i += 2
                guard i + length <= bytes.count else { return nil }
                sets.append(Data(bytes[i..<(i + length)]))
                i += length
            }
        }
        return sets.isEmpty ? nil : (sets, lengthSize)
    }

    /// H.264 の NAL の種類（1 バイト目の下位 5 ビット）。
    static func h264Type(_ nal: Data) -> Int {
        guard let first = nal.first else { return -1 }
        let value: Int = Int(first)
        return value & 0x1F
    }

    /// HEVC の NAL の種類（1 バイト目の 2〜7 ビット目）。
    static func hevcType(_ nal: Data) -> Int {
        guard let first = nal.first else { return -1 }
        let value: Int = Int(first)
        return (value >> 1) & 0x3F
    }

    static func h264Format(_ sets: [Data], lengthSize: Int = 4) throws -> CMVideoFormatDescription {
        let sps: [Data] = sets.filter { (set: Data) -> Bool in ForeignVideoDecoder.h264Type(set) == 7 }
        let pps: [Data] = sets.filter { (set: Data) -> Bool in ForeignVideoDecoder.h264Type(set) == 8 }
        guard let s = sps.first, let p = pps.first else { throw EngineError.unsupported("H.264 の設定（SPS・PPS）が見つかりません") }
        return try ForeignVideoDecoder.withParameterSets([s, p]) { pointers, sizes, count in
            var result: CMVideoFormatDescription?
            let status: OSStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: count,
                                                                                      parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                                      nalUnitHeaderLength: Int32(lengthSize), formatDescriptionOut: &result)
            return status == noErr ? result : nil
        }
    }

    static func hevcFormat(_ sets: [Data], lengthSize: Int = 4) throws -> CMVideoFormatDescription {
        let vps: [Data] = sets.filter { (set: Data) -> Bool in ForeignVideoDecoder.hevcType(set) == 32 }
        let sps: [Data] = sets.filter { (set: Data) -> Bool in ForeignVideoDecoder.hevcType(set) == 33 }
        let pps: [Data] = sets.filter { (set: Data) -> Bool in ForeignVideoDecoder.hevcType(set) == 34 }
        guard let v = vps.first, let s = sps.first, let p = pps.first else { throw EngineError.unsupported("HEVC の設定（VPS・SPS・PPS）が見つかりません") }
        return try ForeignVideoDecoder.withParameterSets([v, s, p]) { pointers, sizes, count in
            var result: CMVideoFormatDescription?
            let status: OSStatus = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: count,
                                                                                      parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                                      nalUnitHeaderLength: Int32(lengthSize), extensions: nil, formatDescriptionOut: &result)
            return status == noErr ? result : nil
        }
    }

    /// パラメーターセットをいったんメモリに並べて、ポインターの配列で渡す。
    static func withParameterSets(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>, Int) -> CMVideoFormatDescription?) throws -> CMVideoFormatDescription {
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        var sizes: [Int] = []
        defer { buffers.forEach { $0.deallocate() } }
        for set in sets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, set.count))
            set.copyBytes(to: buffer, count: set.count)
            buffers.append(buffer)
            sizes.append(set.count)
        }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let made: CMVideoFormatDescription? = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!, sets.count) }
        }
        guard let result = made else { throw EngineError.unsupported("映像の設定を読めません") }
        return result
    }

    // MARK: 中身の並べ方

    /// 開始コード（00 00 01 / 00 00 00 01）で区切られた NAL を取り出す。
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes: [UInt8] = [UInt8](data)
        var starts: [(Int, Int)] = []
        var i: Int = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                starts.append((i, 3))
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Data] = []
        for (k, start) in starts.enumerated() {
            let begin: Int = start.0 + start.1
            var end: Int = k + 1 < starts.count ? starts[k + 1].0 : bytes.count
            while end > begin && bytes[end - 1] == 0 && k + 1 < starts.count { end -= 1 }
            if end > begin { units.append(Data(bytes[begin..<end])) }
        }
        return units
    }

    static func parameterSets(_ data: Data, h264: Bool) -> [Data] {
        return ForeignVideoDecoder.nalUnits(data).filter { unit in
            let first: UInt8 = unit.first ?? 0
            if h264 { return first & 0x1F == 7 || first & 0x1F == 8 }
            let type: UInt8 = (first >> 1) & 0x3F
            return type == 32 || type == 33 || type == 34
        }
    }

    /// 開始コードつきの NAL の並びを、4 バイトの長さつきに直す。
    static func lengthPrefixed(_ data: Data) -> Data {
        var result = Data()
        for unit in ForeignVideoDecoder.nalUnits(data) {
            let n: Int = unit.count
            var length: [UInt8] = []
            for shift in [24, 16, 8, 0] {
                length.append(UInt8(truncatingIfNeeded: n >> shift))
            }
            result.append(contentsOf: length)
            result.append(unit)
        }
        return result
    }

    /// MPEG-4 Part 2 の設定（VOS・VO・VOL）＝最初の VOP（00 00 01 B6）より前。
    static func mpeg4Headers(_ frame: Data) -> Data {
        let bytes: [UInt8] = [UInt8](frame)
        if bytes.count < 4 { return Data() }
        for i in 0..<(bytes.count - 3) where bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 && bytes[i + 3] == 0xB6 {
            return Data(bytes[0..<i])
        }
        return Data()
    }

    /// MPEG-4 の ES_Descriptor（esds の中身）。
    static func esDescriptor(_ specific: Data, objectType: UInt8, streamType: UInt8) -> Data {
        var config = Data([objectType, (streamType << 2) | 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        config.append(ForeignVideoDecoder.descriptor(0x05, specific))
        var es = Data([0x00, 0x01, 0x00])
        es.append(ForeignVideoDecoder.descriptor(0x04, config))
        es.append(ForeignVideoDecoder.descriptor(0x06, Data([0x02])))
        return ForeignVideoDecoder.descriptor(0x03, es)
    }

    static func descriptor(_ tag: UInt8, _ body: Data) -> Data {
        let n: Int = body.count
        var result = Data([tag, 0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F), 0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)])
        result.append(body)
        return result
    }

    /// VP9 の設定（vpcC）。8bit・4:2:0・BT.709 とする。
    static func vpcC() -> Data {
        return Data([1, 0, 0, 0, 0, 31, (8 << 4) | (1 << 1), 1, 1, 1, 0, 0])
    }

    static func sampleBuffer(_ data: Data, format: CMFormatDescription, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        let length: Int = data.count
        if length == 0 { return nil }
        var block: CMBlockBuffer?
        let created: OSStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                                   blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                                   dataLength: length, flags: 0, blockBufferOut: &block)
        guard created == kCMBlockBufferNoErr, let buffer = block else { return nil }
        let copied: OSStatus = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: buffer, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size: Int = length
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    // MARK: Motion JPEG

    /// VP8 の I420 を、H.264 の書き手が読める NV12（ビデオの範囲・BT.601）にする。
    private func vp8PixelBuffer(_ picture: VP8Decoder.Image) -> CVPixelBuffer? {
        let width: Int = picture.width
        let height: Int = picture.height
        if vp8Pool == nil || vp8Size.width != width || vp8Size.height != height {
            var attributes: [String: Any] = [:]
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            attributes[kCVPixelBufferWidthKey as String] = width
            attributes[kCVPixelBufferHeightKey as String] = height
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            vp8Pool = pool
            vp8Size = (width, height)
        }
        guard let pool = vp8Pool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yRow: Int = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cRow: Int = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        picture.y.withUnsafeBufferPointer { (source: UnsafeBufferPointer<UInt8>) in
            guard let from = source.baseAddress else { return }
            for row in 0..<height {
                (yBase + row * yRow).update(from: from + row * width, count: width)
            }
        }
        let cw: Int = picture.chromaWidth
        let rows: Int = min(picture.chromaHeight, CVPixelBufferGetHeightOfPlane(buffer, 1))
        let columns: Int = min(cw, CVPixelBufferGetWidthOfPlane(buffer, 1))
        for row in 0..<rows {
            let line: UnsafeMutablePointer<UInt8> = cBase + row * cRow
            for x in 0..<columns {
                line[2 * x] = picture.u[row * cw + x]
                line[2 * x + 1] = picture.v[row * cw + x]
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    private func decodeJPEG(_ data: Data) -> CVPixelBuffer? {
        let jpeg: Data = MotionJPEG.withHuffmanTables(data)
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width: Int = image.width
        let height: Int = image.height
        if jpegPool == nil {
            var attributes: [String: Any] = [:]
            attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
            attributes[kCVPixelBufferWidthKey as String] = width
            attributes[kCVPixelBufferHeightKey as String] = height
            attributes[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            jpegPool = pool
        }
        guard let pool = jpegPool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &made)
        guard let buffer = made, CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

/// 解読器から出てきたコマを集める（出力の呼び出しは別のスレッドのこともある）。
final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(CVPixelBuffer, Double)] = []
    private(set) var failures: Int = 0

    func add(_ image: CVImageBuffer?, _ time: Double) {
        lock.lock()
        if let image = image {
            frames.append((image, time))
        } else {
            failures += 1
        }
        lock.unlock()
    }

    func take() -> [(CVPixelBuffer, Double)] {
        lock.lock()
        defer { lock.unlock() }
        let result: [(CVPixelBuffer, Double)] = frames
        frames = []
        return result
    }
}

/// Motion JPEG。AVI の MJPEG にはハフマン表（DHT）を省いたものがあるので、そのときは JPEG の標準の表を足す。
enum MotionJPEG {
    static func withHuffmanTables(_ data: Data) -> Data {
        let bytes: [UInt8] = [UInt8](data)
        if bytes.count < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 { return data }
        var i: Int = 2
        while i + 4 <= bytes.count {
            if bytes[i] != 0xFF { break }
            let marker: UInt8 = bytes[i + 1]
            if marker == 0xC4 { return data }
            if marker == 0xDA { break }
            let length: Int = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 2 + length
        }
        var result = Data([0xFF, 0xD8])
        result.append(MotionJPEG.standardTables)
        result.append(contentsOf: bytes[2...])
        return result
    }

    /// JPEG 規格（ITU-T T.81 Annex K.3）の標準ハフマン表。
    static let standardTables: Data = {
        var d = Data([0xFF, 0xC4, 0x01, 0xA2])
        d.append(0x00)
        d.append(contentsOf: [0x00, 0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        d.append(contentsOf: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B])
        d.append(0x01)
        d.append(contentsOf: [0x00, 0x03, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
        d.append(contentsOf: [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B])
        d.append(0x10)
        d.append(contentsOf: [0x00, 0x02, 0x01, 0x03, 0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D])
        d.append(contentsOf: MotionJPEG.lumaAC)
        d.append(0x11)
        d.append(contentsOf: [0x00, 0x02, 0x01, 0x02, 0x04, 0x04, 0x03, 0x04, 0x07, 0x05, 0x04, 0x04, 0x00, 0x01, 0x02, 0x77])
        d.append(contentsOf: MotionJPEG.chromaAC)
        return d
    }()

    static let lumaAC: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
        0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
        0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
        0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA
    ]

    static let chromaAC: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09, 0x23, 0x33, 0x52, 0xF0,
        0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25, 0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26,
        0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
        0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
        0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA,
        0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
        0xF9, 0xFA
    ]
}
#endif
