#if canImport(AVFoundation)
import AVFoundation
import CryptoKit
import Foundation
import Metal
#if canImport(MetricKit)
import MetricKit
#endif

/// 端末の性能の段階（Q81）。メモリ・CPU の数・GPU の世代から自動で決め、設定で変えることもできる。
enum DevicePerformance {
    private static let override = Locked<DeviceTier?>(nil)
    static let detected: DeviceTier = DevicePerformance.detect()

    static var current: DeviceTier {
        return override.get() ?? detected
    }

    static func setOverride(_ tier: DeviceTier?) {
        override.set(tier)
    }

    static func detect() -> DeviceTier {
        let info = ProcessInfo.processInfo
        let memory: Double = Double(info.physicalMemory) / 1_073_741_824
        let modern: Bool = MTLCreateSystemDefaultDevice()?.supportsFamily(.apple7) ?? false
        return DeviceTier.classify(memoryGB: memory, cores: info.activeProcessorCount, modernGPU: modern)
    }
}

/// 端末の性能から、書き出しで選べる上限を決める（4K・120fps は対応端末のみ）。
enum DeviceCapability {
    static func limits() -> DeviceLimits {
        let memory: UInt64 = ProcessInfo.processInfo.physicalMemory
        let gigabyte: UInt64 = 1_073_741_824
        let device: MTLDevice? = MTLCreateSystemDefaultDevice()
        let modern: Bool = device?.supportsFamily(.apple5) ?? false
        let fast: Bool = device?.supportsFamily(.apple7) ?? false
        var resolution: ExportResolution = .p1080
        if memory >= 3 * gigabyte && modern {
            resolution = .p2160
        } else if memory >= 2 * gigabyte {
            resolution = .p1440
        }
        let fps: Int = (fast && memory >= 4 * gigabyte) ? 120 : 60
        let hevc: Bool = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
        return DeviceLimits(maxResolution: resolution, maxFps: fps, supportsHEVC: hevc)
    }

    /// 発熱・低電力モードのときはプレビューを軽くする（Q85）。
    static var shouldReduceLoad: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        return info.thermalState == .serious || info.thermalState == .critical
    }

    static var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "やや高い"
        case .serious: return "高い（プレビューを軽くしています）"
        case .critical: return "非常に高い（処理を控えてください）"
        @unknown default: return "不明"
        }
    }
}

/// キャッシュの自動削除と容量不足の警告（Q84）。
enum CacheManager {
    static let limitBytes: Int64 = 2 * 1_073_741_824

    static func cacheSize() -> Int64 {
        return AppPaths.folderSize(AppPaths.caches)
    }

    static func clearAll() {
        let items: [URL] = (try? FileManager.default.contentsOfDirectory(at: AppPaths.caches, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.lastPathComponent != "Generated" {
            try? FileManager.default.removeItem(at: url)
        }
        FrameRenderer.shared.clearCaches()
    }

    /// 2GB を超えたら、古いものから消す。
    static func autoClean() {
        guard let enumerator = FileManager.default.enumerator(at: AppPaths.caches, includingPropertiesForKeys: [.contentAccessDateKey, .fileSizeKey]) else { return }
        var files: [(URL, Date, Int64)] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values: URLResourceValues? = try? url.resourceValues(forKeys: [.contentAccessDateKey, .fileSizeKey])
            let size: Int64 = Int64(values?.fileSize ?? 0)
            if size == 0 { continue }
            files.append((url, values?.contentAccessDate ?? Date.distantPast, size))
            total += size
        }
        if total <= limitBytes { return }
        for file in files.sorted(by: { $0.1 < $1.1 }) {
            if total <= limitBytes * 3 / 4 { break }
            if file.0.path.contains("/Generated/") { continue }
            try? FileManager.default.removeItem(at: file.0)
            total -= file.2
        }
    }

    /// 必要な容量に足りないときの警告文（足りていれば nil）。
    static func storageWarning(needed: Int64) -> String? {
        let available: Int64 = AppPaths.availableCapacity()
        let margin: Int64 = 500 * 1_048_576
        if available >= needed + margin { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "空き容量が足りない可能性があります（空き \(formatter.string(fromByteCount: available))、必要 \(formatter.string(fromByteCount: needed))）。不要なファイルやキャッシュを削除してください。"
    }
}

/// 端末内の記録（Q86: クラッシュログ、Q89: 同意を得た利用状況）。どちらも外部へは送らず、利用者が自分で共有できるだけにする。
final class Diagnostics: NSObject, @unchecked Sendable {
    static let shared = Diagnostics()

    private let lock = NSLock()
    static var folder: URL { return AppPaths.supportFolder("Diagnostics") }
    private var logURL: URL { return Diagnostics.folder.appendingPathComponent("app.log") }
    private var usageURL: URL { return Diagnostics.folder.appendingPathComponent("usage.json") }

    var usageConsent: Bool {
        get { return UserDefaults.standard.bool(forKey: "usageConsent") }
        set { UserDefaults.standard.set(newValue, forKey: "usageConsent") }
    }

    func start() {
        #if canImport(MetricKit) && os(iOS)
        MXMetricManager.shared.add(self)
        #endif
        log("起動")
    }

    func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let formatter = ISO8601DateFormatter()
        let line: String = formatter.string(from: Date()) + " " + message + "\n"
        if AppPaths.fileSize(logURL) > 512 * 1024 {
            let old: URL = Diagnostics.folder.appendingPathComponent("app.old.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: logURL, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }

    /// 同意があるときだけ、機能ごとの使用回数を端末内に数える。
    func count(_ feature: String) {
        if !usageConsent { return }
        lock.lock()
        defer { lock.unlock() }
        var counts: [String: Int] = [:]
        if let data = try? Data(contentsOf: usageURL), let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = decoded
        }
        counts[feature, default: 0] += 1
        if let data = try? JSONEncoder().encode(counts) {
            try? data.write(to: usageURL, options: .atomic)
        }
    }

    func usageSummary() -> [(String, Int)] {
        guard let data = try? Data(contentsOf: usageURL), let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return [] }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    func clearUsage() {
        try? FileManager.default.removeItem(at: usageURL)
    }

    /// 共有用のファイル（クラッシュログと動作ログ）。
    func reportFiles() -> [URL] {
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(at: Diagnostics.folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent != "usage.json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func crashReportCount() -> Int {
        return reportFiles().filter { $0.lastPathComponent.hasPrefix("crash-") }.count
    }
}

#if canImport(MetricKit) && os(iOS)
extension Diagnostics: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for (index, payload) in payloads.enumerated() {
            let name: String = "crash-\(Int(Date().timeIntervalSince1970))-\(index).json"
            try? payload.jsonRepresentation().write(to: Diagnostics.folder.appendingPathComponent(name))
        }
    }
}
#endif

/// GitHub から追加のテンプレートと LUT を受け取る（データだけ。コードは受け取らない）。
/// 変わったファイルだけを取り、ハッシュを確かめてから「次回起動時に反映」の場所へ置く。
final class ContentUpdater: @unchecked Sendable {
    static let shared = ContentUpdater()
    static let manifestURL = URL(string: "https://raw.githubusercontent.com/prak59459-create/DistroVE/main/content/manifest.json")!
    static let baseURL = URL(string: "https://raw.githubusercontent.com/prak59459-create/DistroVE/main/content/")!
    static let appVersion: String = "0.1.0"

    static var activeFolder: URL { return AppPaths.supportFolder("Content") }
    static var pendingFolder: URL { return AppPaths.support.appendingPathComponent("ContentPending", isDirectory: true) }

    var autoCheck: Bool {
        get { return UserDefaults.standard.bool(forKey: "contentAutoCheck") }
        set { UserDefaults.standard.set(newValue, forKey: "contentAutoCheck") }
    }

    static func localManifest() -> ContentManifest? {
        guard let data = try? Data(contentsOf: activeFolder.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(ContentManifest.self, from: data)
    }

    /// 起動時に呼ぶ。前回ダウンロードした更新があれば入れ替える。
    @discardableResult
    static func applyPending() -> Bool {
        let pending: URL = pendingFolder
        guard FileManager.default.fileExists(atPath: pending.appendingPathComponent("manifest.json").path) else { return false }
        let active: URL = activeFolder
        try? FileManager.default.removeItem(at: active)
        do {
            try FileManager.default.moveItem(at: pending, to: active)
            return true
        } catch {
            return false
        }
    }

    /// 更新を確認し、あればダウンロードする。戻り値は取得したファイル数（0 なら最新）。
    func update(progress: (@Sendable (Double) -> Void)? = nil) async throws -> Int {
        let (data, response) = try await URLSession.shared.data(from: ContentUpdater.manifestURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw EngineError.unreadable("更新情報を取得できません（\(http.statusCode)）")
        }
        let remote: ContentManifest = try JSONDecoder().decode(ContentManifest.self, from: data)
        if !ContentManifest.isCompatible(appVersion: ContentUpdater.appVersion, minimum: remote.minimumAppVersion) {
            throw EngineError.unsupported("この更新には新しい版のアプリが必要です")
        }
        let diff: ContentManifest.Diff = ContentManifest.diff(local: ContentUpdater.localManifest(), remote: remote)
        if diff.isEmpty { return 0 }
        let staging: URL = ContentUpdater.pendingFolder
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // 変わっていないファイルは今のものを引き継ぐ
        let changed = Set<String>(diff.download.map { $0.path })
        for file in remote.files where !changed.contains(file.path) {
            let from: URL = ContentUpdater.activeFolder.appendingPathComponent(file.path)
            let to: URL = staging.appendingPathComponent(file.path)
            try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: from, to: to)
        }
        for (index, file) in diff.download.enumerated() {
            guard let url = URL(string: file.path, relativeTo: ContentUpdater.baseURL) else { continue }
            let (body, _) = try await URLSession.shared.data(from: url)
            let digest: String = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            if digest != file.sha256.lowercased() {
                try? FileManager.default.removeItem(at: staging)
                throw EngineError.unreadable("ダウンロードしたファイルが壊れています：\(file.path)")
            }
            let to: URL = staging.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: to, options: .atomic)
            progress?(Double(index + 1) / Double(diff.download.count))
        }
        try data.write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        return diff.download.count
    }

    /// 受け取ったテンプレート。
    static func installedTemplates() -> [TemplateDefinition] {
        let folder: URL = activeFolder.appendingPathComponent("templates", isDirectory: true)
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [TemplateDefinition] = []
        for url in files where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url) {
                result.append(contentsOf: TemplateLibrary.decode(data))
            }
        }
        return result
    }

    /// 受け取った LUT（名前とファイル）。
    static func installedLUTs() -> [URL] {
        let folder: URL = activeFolder.appendingPathComponent("luts", isDirectory: true)
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "cube" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
#endif
