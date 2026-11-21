import Foundation

/// .disve ファイル（JSON）の読み書き（Q77）。
enum ProjectFile {
    enum LoadError: Error, LocalizedError {
        case newerFormat(Int)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .newerFormat(let version):
                return "新しい版の Distro VE で作られたプロジェクトです（形式 \(version)）。アプリを更新してください。"
            case .unreadable(let detail):
                return "プロジェクトを読み込めませんでした：\(detail)"
            }
        }
    }

    static func encode(_ project: Project, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(project)
    }

    static func decode(_ data: Data) throws -> Project {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project: Project
        do {
            project = try decoder.decode(Project.self, from: data)
        } catch {
            throw LoadError.unreadable(String(describing: error))
        }
        if project.formatVersion > Project.currentFormatVersion {
            throw LoadError.newerFormat(project.formatVersion)
        }
        return migrate(project)
    }

    /// 古い形式から今の形式へ直す（形式が増えたらここに足す）。
    static func migrate(_ project: Project) -> Project {
        var p = project
        if p.tracks.isEmpty || p.mainTrackIndex == nil {
            p.tracks.insert(Track(kind: .video, name: "メイン"), at: 0)
        }
        for i in p.tracks.indices {
            p.tracks[i].sortClips()
        }
        p.formatVersion = Project.currentFormatVersion
        return p
    }

    /// 他の端末へ渡すために ID を振り直した複製を作る。
    static func duplicate(_ project: Project, name: String) -> Project {
        var copy = project
        copy.id = UUID()
        copy.name = name
        copy.createdAt = Date()
        copy.modifiedAt = Date()
        return copy
    }
}
