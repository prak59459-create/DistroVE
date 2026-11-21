import Foundation

/// GitHub から配るデータ（テンプレート・LUT）の一覧。コードは配らない（App Store ガイドライン 2.5.2）。
/// アプリは一覧を取得し、ハッシュが変わったファイルだけをダウンロードして、次回起動時に反映する。
struct ContentManifest: Codable, Equatable, Sendable {
    struct File: Codable, Hashable, Sendable {
        /// content フォルダーからの相対パス（例: "templates/xxx.json"）
        var path: String
        var sha256: String
        var size: Int
        /// "template" または "lut"
        var kind: String
    }

    var version: Int
    var minimumAppVersion: String?
    var files: [File]

    struct Diff: Equatable, Sendable {
        var download: [File]
        var remove: [String]

        var isEmpty: Bool { return download.isEmpty && remove.isEmpty }
    }

    /// 手元の一覧と比べて、取りに行くファイルと消すファイルを決める。
    static func diff(local: ContentManifest?, remote: ContentManifest) -> Diff {
        var localByPath: [String: File] = [:]
        for f in local?.files ?? [] {
            localByPath[f.path] = f
        }
        var download: [File] = []
        var remotePaths = Set<String>()
        for f in remote.files {
            remotePaths.insert(f.path)
            if !isSafePath(f.path) { continue }
            if let existing = localByPath[f.path], existing.sha256.lowercased() == f.sha256.lowercased() { continue }
            download.append(f)
        }
        var remove: [String] = []
        for f in local?.files ?? [] where !remotePaths.contains(f.path) {
            remove.append(f.path)
        }
        return Diff(download: download, remove: remove.sorted())
    }

    /// ".." や絶対パスで保存先の外に書かないようにする。
    static func isSafePath(_ path: String) -> Bool {
        if path.isEmpty || path.hasPrefix("/") || path.contains("..") || path.contains("\\") { return false }
        let allowed: Set<String> = ["templates", "luts"]
        guard let first = path.split(separator: "/").first else { return false }
        return allowed.contains(String(first))
    }

    /// アプリの版がこの一覧の対象か（"0.1.0" 形式を比べる）。
    static func isCompatible(appVersion: String, minimum: String?) -> Bool {
        guard let minimum = minimum else { return true }
        let a: [Int] = appVersion.split(separator: ".").map { Int($0) ?? 0 }
        let b: [Int] = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let count: Int = max(a.count, b.count)
        for i in 0..<count {
            let x: Int = i < a.count ? a[i] : 0
            let y: Int = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return true
    }
}
