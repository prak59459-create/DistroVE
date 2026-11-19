#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import Foundation

// MARK: 時刻の変換

extension Time {
    var cmTime: CMTime {
        return CMTime(value: ticks, timescale: CMTimeScale(Time.timescale))
    }

    init(_ time: CMTime) {
        if !time.isValid || time.isIndefinite || time.timescale == 0 {
            self.init(ticks: 0)
            return
        }
        if time.timescale == CMTimeScale(Time.timescale) {
            self.init(ticks: time.value)
            return
        }
        let converted: CMTime = CMTimeConvertScale(time, timescale: CMTimeScale(Time.timescale), method: .roundHalfAwayFromZero)
        self.init(ticks: converted.value)
    }
}

extension TimeRange {
    var cmTimeRange: CMTimeRange {
        return CMTimeRange(start: start.cmTime, duration: duration.cmTime)
    }
}

// MARK: 色

extension RGBA {
    var cgColor: CGColor {
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let components: [CGFloat] = [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0, alpha: 1)
    }

    var ciColor: CIColor {
        return CIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

/// スレッド間で共有する値を NSLock で守る小さな入れ物。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    @discardableResult
    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// エンジン内のエラー。
enum EngineError: Error, LocalizedError {
    case missingMedia(String)
    case unreadable(String)
    case exportFailed(String)
    case cancelled
    case unsupported(String)
    case notAuthorized(String)

    var errorDescription: String? {
        switch self {
        case .missingMedia(let name): return "素材が見つかりません：\(name)"
        case .unreadable(let detail): return "読み込めませんでした：\(detail)"
        case .exportFailed(let detail): return "書き出しに失敗しました：\(detail)"
        case .cancelled: return "中止しました"
        case .unsupported(let detail): return "対応していません：\(detail)"
        case .notAuthorized(let detail): return "許可が必要です：\(detail)"
        }
    }
}

/// アプリが使うフォルダー。
enum AppPaths {
    /// テストでは一時フォルダーに差し替える
    static var overrideRoot: URL?

    static var documents: URL {
        if let root = overrideRoot {
            let url: URL = root.appendingPathComponent("Documents", isDirectory: true)
            ensure(url)
            return url
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var support: URL {
        let base: URL = overrideRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url: URL = base.appendingPathComponent("DistroVE", isDirectory: true)
        ensure(url)
        return url
    }

    static var caches: URL {
        let base: URL = overrideRoot?.appendingPathComponent("Caches", isDirectory: true) ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url: URL = base.appendingPathComponent("DistroVE", isDirectory: true)
        ensure(url)
        return url
    }

    /// プロジェクト（.disve）の置き場所。ファイル App から見えるよう Documents の下に置く
    static var projects: URL {
        let url: URL = documents.appendingPathComponent("Projects", isDirectory: true)
        ensure(url)
        return url
    }

    /// 取り込んだ素材（コピー）の置き場所
    static var media: URL {
        let url: URL = documents.appendingPathComponent("Media", isDirectory: true)
        ensure(url)
        return url
    }

    static func cacheFolder(_ name: String) -> URL {
        let url: URL = caches.appendingPathComponent(name, isDirectory: true)
        ensure(url)
        return url
    }

    static func supportFolder(_ name: String) -> URL {
        let url: URL = support.appendingPathComponent(name, isDirectory: true)
        ensure(url)
        return url
    }

    static func ensure(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        let base: String = sanitize(name)
        var candidate: URL = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var index: Int = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(index)").appendingPathExtension(ext)
            index += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned: String = name.components(separatedBy: invalid).joined(separator: "_")
        let trimmed: String = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "untitled" }
        return String(trimmed.prefix(80))
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values: URLResourceValues? = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += fileSize(file)
        }
        return total
    }

    /// 端末の空き容量（大事な用途に使える量）。
    static func availableCapacity() -> Int64 {
        let values: URLResourceValues? = try? documents.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage {
            return important
        }
        return Int64.max
    }
}
#endif
