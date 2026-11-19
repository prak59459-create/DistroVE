#if canImport(AVFoundation)
import CoreGraphics
import Foundation
import ImageIO

/// プロジェクトの保存・一覧・バックアップ・復元（Q39, Q77, Q79, Q86）。
final class ProjectStore: @unchecked Sendable {
    static let shared = ProjectStore()

    struct Summary: Identifiable, Hashable {
        let id: UUID
        let name: String
        let modifiedAt: Date
        let duration: Time
        let aspect: AspectPreset
        let clipCount: Int
        let thumbnail: URL?
    }

    private let lock = NSLock()

    func fileURL(_ id: UUID) -> URL {
        return AppPaths.projects.appendingPathComponent(id.uuidString).appendingPathExtension(Project.fileExtension)
    }

    func thumbnailURL(_ id: UUID) -> URL {
        return AppPaths.projects.appendingPathComponent(id.uuidString + ".jpg")
    }

    // MARK: 一覧

    func list() -> [Summary] {
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(at: AppPaths.projects, includingPropertiesForKeys: nil)) ?? []
        var result: [Summary] = []
        for url in files where url.pathExtension == Project.fileExtension {
            guard let data = try? Data(contentsOf: url), let project = try? ProjectFile.decode(data) else { continue }
            let thumb: URL = thumbnailURL(project.id)
            let hasThumb: Bool = FileManager.default.fileExists(atPath: thumb.path)
            result.append(Summary(id: project.id, name: project.name, modifiedAt: project.modifiedAt, duration: project.duration,
                                  aspect: project.canvas.aspect, clipCount: project.clipCount, thumbnail: hasThumb ? thumb : nil))
        }
        result.sort { $0.modifiedAt > $1.modifiedAt }
        return result
    }

    // MARK: 保存と読み込み

    /// 自動保存・手動保存の両方で使う。書き込みは原子的（途中で落ちても前のファイルが残る）。
    func save(_ project: Project) throws {
        lock.lock()
        defer { lock.unlock() }
        let data: Data = try ProjectFile.encode(project)
        try data.write(to: fileURL(project.id), options: .atomic)
    }

    func load(_ id: UUID) throws -> Project {
        let data: Data = try Data(contentsOf: fileURL(id))
        return try ProjectFile.decode(data)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: fileURL(id))
        try? FileManager.default.removeItem(at: thumbnailURL(id))
        try? FileManager.default.removeItem(at: backupFolder(id))
    }

    func duplicate(_ id: UUID) throws -> Project {
        let original: Project = try load(id)
        let copy: Project = ProjectFile.duplicate(original, name: original.name + " のコピー")
        try save(copy)
        if let data = try? Data(contentsOf: thumbnailURL(id)) {
            try? data.write(to: thumbnailURL(copy.id))
        }
        return copy
    }

    /// 他の端末やファイル App から受け取った .disve を取り込む。同じ ID があれば新しい ID にする。
    func importProject(from url: URL) throws -> Project {
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data = try Data(contentsOf: url)
        var project: Project = try ProjectFile.decode(data)
        if FileManager.default.fileExists(atPath: fileURL(project.id).path) {
            project = ProjectFile.duplicate(project, name: project.name)
        }
        try save(project)
        return project
    }

    func saveThumbnail(_ image: CGImage, for id: UUID) {
        let url: URL = thumbnailURL(id)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    // MARK: バックアップ（Q79）

    func backupFolder(_ id: UUID) -> URL {
        return AppPaths.supportFolder("Backups").appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// 手動保存のたび・編集 5 分ごとに世代を残す（最大 20 世代）。
    func backup(_ project: Project) {
        let folder: URL = backupFolder(project.id)
        AppPaths.ensure(folder)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url: URL = folder.appendingPathComponent(formatter.string(from: Date())).appendingPathExtension(Project.fileExtension)
        if let data = try? ProjectFile.encode(project) {
            try? data.write(to: url, options: .atomic)
        }
        var files: [URL] = backups(project.id)
        while files.count > 20 {
            let oldest: URL = files.removeLast()
            try? FileManager.default.removeItem(at: oldest)
        }
    }

    /// 新しい順。
    func backups(_ id: UUID) -> [URL] {
        let files: [URL] = (try? FileManager.default.contentsOfDirectory(at: backupFolder(id), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == Project.fileExtension }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func restore(backup url: URL) throws -> Project {
        let data: Data = try Data(contentsOf: url)
        var project: Project = try ProjectFile.decode(data)
        project.modifiedAt = Date()
        try save(project)
        return project
    }

    // MARK: 異常終了からの復元（Q86）

    private var sessionURL: URL {
        return AppPaths.support.appendingPathComponent("session.json")
    }

    private struct SessionMarker: Codable {
        var projectID: UUID?
        var startedAt: Date
    }

    /// 編集を始めたときに印を付け、正常に閉じたら消す。次の起動で印が残っていれば、前回は途中で終わったとわかる。
    func markEditing(_ id: UUID?) {
        let marker = SessionMarker(projectID: id, startedAt: Date())
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: sessionURL, options: .atomic)
        }
    }

    func markClosed() {
        try? FileManager.default.removeItem(at: sessionURL)
    }

    /// 前回、編集中に落ちたプロジェクト。
    func interruptedProject() -> UUID? {
        guard let data = try? Data(contentsOf: sessionURL), let marker = try? JSONDecoder().decode(SessionMarker.self, from: data) else { return nil }
        guard let id = marker.projectID, FileManager.default.fileExists(atPath: fileURL(id).path) else { return nil }
        return id
    }

    // MARK: クラウド同期（Q79。ファイル App で選んだフォルダー＝iCloud Drive などと同期する）

    private let syncBookmarkKey: String = "syncFolderBookmark"

    var syncFolderName: String? {
        return resolveSyncFolder()?.lastPathComponent
    }

    func setSyncFolder(_ url: URL?) throws {
        guard let url = url else {
            UserDefaults.standard.removeObject(forKey: syncBookmarkKey)
            return
        }
        let scoped: Bool = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: syncBookmarkKey)
    }

    private func resolveSyncFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: syncBookmarkKey) else { return nil }
        var stale: Bool = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    struct SyncResult {
        var uploaded: Int = 0
        var downloaded: Int = 0
        var mediaCopied: Int = 0
    }

    /// 新しいほうを残す単純な同期。コピーした素材も一緒に送る（参照している素材は送らない）。
    func sync() throws -> SyncResult {
        guard let root = resolveSyncFolder() else { throw EngineError.notAuthorized("同期するフォルダーを選んでください") }
        let scoped: Bool = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let remoteProjects: URL = root.appendingPathComponent("DistroVE/Projects", isDirectory: true)
        let remoteMedia: URL = root.appendingPathComponent("DistroVE/Media", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteProjects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteMedia, withIntermediateDirectories: true)
        var result = SyncResult()
        var localByID: [UUID: Project] = [:]
        for summary in list() {
            if let p = try? load(summary.id) { localByID[p.id] = p }
        }
        var remoteByID: [UUID: Project] = [:]
        let remoteFiles: [URL] = (try? FileManager.default.contentsOfDirectory(at: remoteProjects, includingPropertiesForKeys: nil)) ?? []
        for url in remoteFiles where url.pathExtension == Project.fileExtension {
            if let data = try? Data(contentsOf: url), let p = try? ProjectFile.decode(data) { remoteByID[p.id] = p }
        }
        for (id, local) in localByID {
            if let remote = remoteByID[id], remote.modifiedAt >= local.modifiedAt { continue }
            let data: Data = try ProjectFile.encode(local)
            try data.write(to: remoteProjects.appendingPathComponent(id.uuidString + "." + Project.fileExtension), options: .atomic)
            result.uploaded += 1
            result.mediaCopied += copyMedia(of: local, from: AppPaths.media, to: remoteMedia)
        }
        for (id, remote) in remoteByID {
            if let local = localByID[id], local.modifiedAt >= remote.modifiedAt { continue }
            try save(remote)
            result.downloaded += 1
            result.mediaCopied += copyMedia(of: remote, from: remoteMedia, to: AppPaths.media)
        }
        return result
    }

    private func copyMedia(of project: Project, from source: URL, to destination: URL) -> Int {
        var count: Int = 0
        for asset in project.media where asset.storage != .referenced {
            for path in [asset.relativePath, asset.proxyPath].compactMap({ $0 }) {
                let from: URL = source.appendingPathComponent(path)
                let to: URL = destination.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: to.path) || !FileManager.default.fileExists(atPath: from.path) { continue }
                try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? FileManager.default.copyItem(at: from, to: to)) != nil { count += 1 }
            }
        }
        return count
    }

    // MARK: 素材の片付け

    /// どのプロジェクトからも使われていない素材ファイルを消す。戻り値は空いた容量。
    func cleanUnusedMedia() -> Int64 {
        var used = Set<String>()
        for summary in list() {
            guard let project = try? load(summary.id) else { continue }
            for asset in project.media {
                if let p = asset.relativePath { used.insert(p) }
                if let p = asset.proxyPath { used.insert(p) }
                if let p = asset.reversedPath { used.insert(p) }
            }
            for track in project.tracks {
                for clip in track.clips {
                    if let p = clip.audio.processing.renderedPath { used.insert(p) }
                }
            }
        }
        var freed: Int64 = 0
        let root: URL = AppPaths.media
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return 0 }
        let rootPath: String = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let values: URLResourceValues? = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            var relative: String = url.standardizedFileURL.path
            if relative.hasPrefix(rootPath) {
                relative = String(relative.dropFirst(rootPath.count))
                if relative.hasPrefix("/") { relative.removeFirst() }
            }
            if used.contains(relative) { continue }
            freed += AppPaths.fileSize(url)
            try? FileManager.default.removeItem(at: url)
        }
        return freed
    }
}
#endif
