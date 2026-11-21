#if canImport(AVFoundation)
import AVFoundation
import CoreVideo
import Foundation

/// 合成の土台にする黒い短い動画。画像やテキストだけのタイムラインでも合成処理が毎フレーム呼ばれるようにする。
enum PlaceholderVideo {
    static let seconds: Double = 2
    private static let cached = Locked<URL?>(nil)

    static func url() async throws -> URL {
        if let url = cached.get(), FileManager.default.fileExists(atPath: url.path) { return url }
        let url: URL = AppPaths.cacheFolder("Generated").appendingPathComponent("placeholder-v1.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await write(to: url)
        }
        cached.set(url)
        return url
    }

    private static func write(to url: URL) async throws {
        let temp: URL = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64,
            kCVPixelBufferHeightKey as String: 64
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        if !writer.startWriting() {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "placeholder")
        }
        writer.startSession(atSourceTime: .zero)
        let frames: Int = Int(seconds * 30)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixels = buffer else { break }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, 0, CVPixelBufferGetDataSize(pixels))
                // アルファを不透明に
                let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(pixels)
                let height: Int = CVPixelBufferGetHeight(pixels)
                let width: Int = CVPixelBufferGetWidth(pixels)
                let pointer: UnsafeMutablePointer<UInt8> = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        pointer[y * bytesPerRow + x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw EngineError.exportFailed(writer.error?.localizedDescription ?? "placeholder")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}

/// 内蔵 BGM・効果音を初回に合成してファイルにし、素材として取り込む（Q54）。
enum SoundLibraryStore {
    static func fileURL(for id: String) -> URL {
        return AppPaths.supportFolder("Sounds").appendingPathComponent(id + ".wav")
    }

    /// 合成済みのファイル（無ければ作る）。
    static func ensureFile(_ id: String) throws -> URL {
        let url: URL = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let samples = SoundLibrary.render(id) else {
            throw EngineError.missingMedia(id)
        }
        let data: Data = SoundLibrary.wav(samples, sampleRate: SoundLibrary.sampleRate)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 素材フォルダーへコピーして MediaAsset にする。
    static func importSound(_ id: String) async throws -> MediaAsset {
        let source: URL = try ensureFile(id)
        let name: String = SoundLibrary.definition(id)?.name ?? id
        let destination: URL = AppPaths.uniqueURL(in: AppPaths.media, name: id, ext: "wav")
        try FileManager.default.copyItem(at: source, to: destination)
        var asset: MediaAsset = try await MediaStore.shared.registerGenerated(fileName: destination.lastPathComponent, kind: .audio, name: name)
        asset.libraryID = id
        return asset
    }
}
#endif
