import Foundation

/// 素材の種類。
enum MediaKind: String, Codable, Sendable {
    case video
    case audio
    case image
    case gif
    /// 3D モデル（USDZ・OBJ・STL・PLY など。Q50）
    case model3D
}

/// 素材ファイルの持ち方（Q78: 参照かコピーかを選べる）。
enum MediaStorage: String, Codable, Sendable {
    /// アプリ内の素材フォルダーにコピーした
    case copied
    /// 元の場所を参照する（ブックマークで再アクセス）
    case referenced
    /// アプリが作った（内蔵 BGM・効果音・手書き・フリーズ画像など）
    case generated
}

/// プロジェクトに取り込んだ素材。
struct MediaAsset: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var kind: MediaKind
    var name: String
    var storage: MediaStorage
    /// copied / generated のとき、素材フォルダーからの相対パス
    var relativePath: String?
    /// referenced のときのセキュリティスコープ付きブックマーク
    var bookmark: Data?
    /// 長さ（静止画は 0）
    var duration: Time
    /// 表示サイズ（回転を反映した幅・高さ）
    var width: Int
    var height: Int
    var frameRate: Double
    var hasVideo: Bool
    var hasAudio: Bool
    var codec: String
    var fileSize: Int64
    /// 軽い代替動画（プロキシ）の相対パス
    var proxyPath: String?
    /// 逆再生用に作った動画の相対パス
    var reversedPath: String?
    var importedAt: Date
    /// 内蔵素材の識別子（内蔵 BGM など）
    var libraryID: String?

    init(kind: MediaKind, name: String, storage: MediaStorage) {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.storage = storage
        self.relativePath = nil
        self.bookmark = nil
        self.duration = .zero
        self.width = 0
        self.height = 0
        self.frameRate = 30
        self.hasVideo = kind == .video || kind == .image || kind == .gif || kind == .model3D
        self.hasAudio = kind == .audio
        self.codec = ""
        self.fileSize = 0
        self.proxyPath = nil
        self.reversedPath = nil
        self.importedAt = Date()
        self.libraryID = nil
    }

    var isVisual: Bool {
        return kind == .video || kind == .image || kind == .gif || kind == .model3D
    }

    /// 長さに上限があるか（静止画は自由に伸ばせる）。
    var hasFiniteDuration: Bool {
        return kind == .video || kind == .audio
    }

    var aspectRatio: Double {
        if width <= 0 || height <= 0 { return 16.0 / 9.0 }
        return Double(width) / Double(height)
    }

    /// 4K 超や HEVC 10bit など重い素材はプロキシ作成をすすめる。
    var recommendsProxy: Bool {
        if kind != .video { return false }
        return max(width, height) > 2000 || frameRate > 61
    }
}

/// 読み込める形式の判定（Q71）。MKV / WebM / AVI は iPad 標準の仕組みで読めないため、現時点では案内だけ出す。
enum MediaFormatSupport {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "hevc", "3gp"]
    static let audioExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "aif", "aiff", "caf", "flac"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    static let gifExtensions: Set<String> = ["gif"]
    static let modelExtensions: Set<String> = ["usdz", "usd", "usda", "usdc", "obj", "stl", "ply", "abc"]
    static let unsupportedExtensions: Set<String> = ["mkv", "webm", "avi", "wmv", "flv"]

    static func kind(forExtension ext: String) -> MediaKind? {
        let lower: String = ext.lowercased()
        if videoExtensions.contains(lower) { return .video }
        if audioExtensions.contains(lower) { return .audio }
        if gifExtensions.contains(lower) { return .gif }
        if imageExtensions.contains(lower) { return .image }
        if modelExtensions.contains(lower) { return .model3D }
        return nil
    }

    static func unsupportedReason(forExtension ext: String) -> String? {
        let lower: String = ext.lowercased()
        if unsupportedExtensions.contains(lower) {
            return "\(lower.uppercased()) 形式は現在読み込めません。MP4 または MOV に変換してから取り込んでください。"
        }
        if kind(forExtension: lower) == nil {
            return "この形式（.\(lower)）には対応していません。"
        }
        return nil
    }
}
