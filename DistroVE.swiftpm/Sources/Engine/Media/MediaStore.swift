#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import Foundation
import ImageIO

/// 素材ファイルの取り込み・場所の解決・情報の読み取り（Q67, Q71, Q78）。
final class MediaStore: @unchecked Sendable {
    static let shared = MediaStore()

    enum Variant {
        case original
        case proxy
        case reversed
        /// オプティカルフローでコマを足したもの（Q99）
        case interpolated
    }

    private let openScopes = Locked<[UUID: URL]>([:])
    private let resolvedBookmarks = Locked<[UUID: URL]>([:])

    // MARK: 場所

    /// 素材の実ファイル。プロキシや逆再生ファイルが無いときは元のファイルを返す。
    func url(for asset: MediaAsset, variant: Variant = .original) -> URL? {
        switch variant {
        case .proxy:
            if let path = asset.proxyPath {
                let url: URL = AppPaths.media.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        case .reversed:
            if let path = asset.reversedPath {
                let url: URL = AppPaths.media.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        case .interpolated:
            if let path = asset.interpolated?.path {
                let url: URL = AppPaths.media.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        case .original:
            break
        }
        switch asset.storage {
        case .copied, .generated:
            guard let path = asset.relativePath else { return nil }
            return AppPaths.media.appendingPathComponent(path)
        case .referenced:
            return resolveBookmark(asset)
        }
    }

    func exists(_ asset: MediaAsset) -> Bool {
        guard let url = url(for: asset) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func resolveBookmark(_ asset: MediaAsset) -> URL? {
        if let cached = resolvedBookmarks.get()[asset.id] { return cached }
        guard let data = asset.bookmark else { return nil }
        var stale: Bool = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if url.startAccessingSecurityScopedResource() {
            openScopes.update { $0[asset.id] = url }
        }
        resolvedBookmarks.update { $0[asset.id] = url }
        return url
    }

    /// 参照している素材のアクセス権を返す（プロジェクトを閉じたとき）。
    func closeReferences() {
        let scopes: [UUID: URL] = openScopes.get()
        for (_, url) in scopes {
            url.stopAccessingSecurityScopedResource()
        }
        openScopes.set([:])
        resolvedBookmarks.set([:])
    }

    // MARK: 取り込み

    /// ファイルを取り込む。copy が false なら元の場所を参照する（ブックマーク）。
    func importFile(at source: URL, copy: Bool) async throws -> MediaAsset {
        let ext: String = source.pathExtension
        if let reason = MediaFormatSupport.unsupportedReason(forExtension: ext) {
            throw EngineError.unsupported(reason)
        }
        if MediaFormatSupport.convertedExtensions.contains(ext.lowercased()) {
            return try await importConverted(at: source, progress: nil).asset
        }
        guard let kind = MediaFormatSupport.kind(forExtension: ext) else {
            throw EngineError.unsupported(ext)
        }
        let scoped: Bool = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let name: String = source.deletingPathExtension().lastPathComponent
        var asset = MediaAsset(kind: kind, name: name, storage: copy ? .copied : .referenced)
        let fileURL: URL
        if copy {
            let destination: URL = AppPaths.uniqueURL(in: AppPaths.media, name: name, ext: ext.lowercased())
            try FileManager.default.copyItem(at: source, to: destination)
            asset.relativePath = destination.lastPathComponent
            fileURL = destination
        } else {
            asset.bookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            fileURL = source
        }
        asset.fileSize = AppPaths.fileSize(fileURL)
        try await probe(&asset, url: fileURL)
        return asset
    }

    struct ConvertedImport {
        let asset: MediaAsset
        /// ファイルの中にあった字幕（素材の時刻）
        let subtitles: [SubtitleCue]
        let notes: [String]
    }

    /// MKV・WebM・AVI を MP4（音声だけなら M4A）に変えて取り込む（Q71）。元のファイルは残さない。
    func importConverted(at source: URL, progress: (@Sendable (Double) -> Void)?) async throws -> ConvertedImport {
        let scoped: Bool = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        #if canImport(VideoToolbox)
        let result: ForeignMediaConverter.Result = try await ForeignMediaConverter.convert(source, into: AppPaths.media, progress: progress)
        var asset = MediaAsset(kind: result.kind, name: source.deletingPathExtension().lastPathComponent, storage: .copied)
        asset.relativePath = result.url.lastPathComponent
        asset.fileSize = AppPaths.fileSize(result.url)
        try await probe(&asset, url: result.url)
        asset.codec = asset.codec.isEmpty ? result.container : asset.codec + "（" + result.container + " から変換）"
        return ConvertedImport(asset: asset, subtitles: result.subtitles, notes: result.notes)
        #else
        throw EngineError.unsupported(source.pathExtension)
        #endif
    }

    /// アプリ内で作ったファイル（すでに Media フォルダーにある）を素材にする。
    func registerGenerated(fileName: String, kind: MediaKind, name: String) async throws -> MediaAsset {
        var asset = MediaAsset(kind: kind, name: name, storage: .generated)
        asset.relativePath = fileName
        let url: URL = AppPaths.media.appendingPathComponent(fileName)
        asset.fileSize = AppPaths.fileSize(url)
        try await probe(&asset, url: url)
        return asset
    }

    /// 長さ・大きさ・音声の有無などを調べる。
    func probe(_ asset: inout MediaAsset, url: URL) async throws {
        switch asset.kind {
        case .model3D:
            #if canImport(MetalKit)
            let model: Geometry3D.LoadedModel = try Geometry3D.loadModel(url: url)
            asset.codec = "\(model.mesh.triangleCount) 面"
            #endif
            asset.width = 1024
            asset.height = 1024
            asset.hasVideo = true
            asset.hasAudio = false
        case .image:
            let size: CGSize = MediaStore.imageSize(url)
            asset.width = Int(size.width)
            asset.height = Int(size.height)
            asset.hasVideo = true
            asset.hasAudio = false
        case .gif:
            let info: (size: CGSize, duration: Double, frames: Int) = MediaStore.gifInfo(url)
            asset.width = Int(info.size.width)
            asset.height = Int(info.size.height)
            asset.duration = Time(seconds: info.duration)
            asset.hasVideo = true
            asset.hasAudio = false
            if info.frames <= 1 { asset.kind = .image }
        case .video, .audio:
            let avAsset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let duration: CMTime = try await avAsset.load(.duration)
            asset.duration = Time(duration)
            let videoTracks: [AVAssetTrack] = try await avAsset.loadTracks(withMediaType: .video)
            let audioTracks: [AVAssetTrack] = try await avAsset.loadTracks(withMediaType: .audio)
            asset.hasAudio = !audioTracks.isEmpty
            asset.hasVideo = !videoTracks.isEmpty
            if let track = videoTracks.first {
                let natural: CGSize = try await track.load(.naturalSize)
                let transform: CGAffineTransform = try await track.load(.preferredTransform)
                let rate: Float = try await track.load(.nominalFrameRate)
                let display: CGRect = CGRect(origin: .zero, size: natural).applying(transform)
                asset.width = Int(abs(display.width).rounded())
                asset.height = Int(abs(display.height).rounded())
                asset.frameRate = rate > 0 ? Double(rate) : 30
                let formats: [CMFormatDescription] = try await track.load(.formatDescriptions)
                if let format = formats.first {
                    asset.codec = MediaStore.fourCC(CMFormatDescriptionGetMediaSubType(format))
                }
                asset.kind = .video
            } else if asset.hasAudio {
                asset.kind = .audio
            } else {
                throw EngineError.unreadable("映像も音声も見つかりません")
            }
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text: String = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func imageSize(_ url: URL) -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return CGSize(width: 1920, height: 1080)
        }
        let w: Double = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 1920
        let h: Double = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 1080
        let orientation: Int = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // 5〜8 は 90 度回転している
        if orientation >= 5 && orientation <= 8 {
            return CGSize(width: h, height: w)
        }
        return CGSize(width: w, height: h)
    }

    static func gifInfo(_ url: URL) -> (size: CGSize, duration: Double, frames: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return (CGSize(width: 480, height: 480), 0, 0)
        }
        let count: Int = CGImageSourceGetCount(source)
        var total: Double = 0
        for i in 0..<count {
            total += gifDelay(source, index: i)
        }
        let size: CGSize = imageSize(url)
        return (size, total, count)
    }

    static func gifDelay(_ source: CGImageSource, index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        var delay: Double = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue ?? 0
        if delay < 0.011 {
            delay = (gif[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
        }
        return delay < 0.011 ? 0.1 : delay
    }

    // MARK: 画像を書き出して素材にする

    /// CGImage を PNG で保存して素材にする（フリーズフレーム・手書き・ステッカーなど）。
    func saveImage(_ image: CGImage, name: String) async throws -> MediaAsset {
        let url: URL = AppPaths.uniqueURL(in: AppPaths.media, name: name, ext: "png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw EngineError.exportFailed("PNG を作れませんでした")
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            throw EngineError.exportFailed("PNG を保存できませんでした")
        }
        return try await registerGenerated(fileName: url.lastPathComponent, kind: .image, name: name)
    }

    /// 動画の 1 コマを画像にする（フリーズフレーム）。
    func frameImage(asset: MediaAsset, at time: Time, maxSize: CGSize = CGSize(width: 3840, height: 3840)) async throws -> CGImage {
        guard let url = url(for: asset) else { throw EngineError.missingMedia(asset.name) }
        let avAsset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: avAsset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = maxSize
        let result = try await generator.image(at: time.cmTime)
        return result.image
    }

    /// 使われていない素材ファイルを消す（コピーと生成物だけ。参照している元ファイルは消さない）。
    func deleteFiles(of asset: MediaAsset) {
        if asset.storage != .referenced, let path = asset.relativePath {
            try? FileManager.default.removeItem(at: AppPaths.media.appendingPathComponent(path))
        }
        if let proxy = asset.proxyPath {
            try? FileManager.default.removeItem(at: AppPaths.media.appendingPathComponent(proxy))
        }
        if let reversed = asset.reversedPath {
            try? FileManager.default.removeItem(at: AppPaths.media.appendingPathComponent(reversed))
        }
        if let smooth = asset.interpolated?.path {
            try? FileManager.default.removeItem(at: AppPaths.media.appendingPathComponent(smooth))
        }
    }
}
#endif
