import Foundation

/// コマの間の作り方（Q99）。速さを変えたとき、素材とプロジェクトのフレームレートが違うとき、モーションブラーを付けるときに使う。
/// Premiere Pro の「時間補間（フレームサンプリング・フレームブレンド・オプティカルフロー）」と同じ考え方。
enum FrameInterpolation: String, Codable, CaseIterable, Sendable {
    /// いちばん近いコマをそのまま使う（ふつうの再生と同じ。作る手間なし）
    case sampling
    /// 前後のコマを重ねて間を作る（速い。動きが大きいと二重に見える）
    case blending
    /// 前後のコマの動きを読んで間のコマを作る（いちばんなめらか。作るのに時間がかかる）
    case opticalFlow

    var label: String {
        switch self {
        case .sampling: return "コマの繰り返し"
        case .blending: return "コマの合成"
        case .opticalFlow: return "光学フロー"
        }
    }

    var detail: String {
        switch self {
        case .sampling: return "近いコマをそのまま使います。スローにするとカクカクしますが、作る時間はかかりません。"
        case .blending: return "前後のコマを重ねて間を作ります。短い時間で作れますが、速い動きは二重に見えます。"
        case .opticalFlow: return "前後のコマの動きを読んで、間のコマを新しく作ります。いちばんなめらかです。"
        }
    }

    /// クリップに付ける短い印
    var badge: String? {
        switch self {
        case .sampling: return nil
        case .blending: return "合成"
        case .opticalFlow: return "フロー"
        }
    }
}

/// モーションブラーの強さ（シャッターが開いている割合。0.5 = 180°）。
enum MotionBlur {
    static let choices: [Double] = [0, 0.25, 0.5, 0.75, 1]

    static func label(_ shutter: Double) -> String {
        if shutter <= 0.001 { return "なし" }
        return "\(Int((shutter * 360).rounded()))°"
    }
}

/// 作ったコマのファイルの状態（画面の表示用）。
enum RetimeStatus: Equatable, Sendable {
    /// コマの繰り返しで足りる（作らなくてよい）
    case notNeeded
    /// 作ってある
    case ready
    /// まだ作っていない（速さや長さを変えたら作り直す）
    case missing
    /// 先に逆再生の準備が要る
    case needsReverse
}

/// 書き出す 1 コマ。時刻はすべて秒。
struct RetimeFrame: Equatable, Sendable {
    /// 作るファイルの中の時刻（クリップの先頭が 0）
    var outputTime: Double
    /// このコマが写す素材の時刻（使うファイルの中の時刻）
    var sourceTime: Double
    /// モーションブラーのとき、シャッターが開いている素材の時刻の範囲（ブラーなしなら sourceTime と同じ）
    var exposureStart: Double
    var exposureEnd: Double

    var hasExposure: Bool { return exposureEnd - exposureStart > 1e-6 }
}

/// クリップの速さ・速度カーブ・フレームレートから、タイムラインの 1 コマずつが素材のどの時刻を写すかを決める（Q34, Q99）。
/// 作ったファイルはタイムラインのコマと 1 対 1 に対応するので、どんな速さ・カーブ・フレームレートでもコマの時刻がずれない。
struct RetimePlan: Equatable, Sendable {
    /// 作り方が変わったら上げる（古いキャッシュを使わないように）
    static let version: Int = 1
    static let folder: String = "Retimed"

    let frames: [RetimeFrame]
    /// 作るファイルの長さ（クリップのタイムライン上の長さ）
    let duration: Double
    /// 読む必要のある素材の範囲（秒。ブラーのぶんを含む）
    let sourceStart: Double
    let sourceEnd: Double
    let fps: Double
    /// 実際に使う作り方（ブラーだけを付けるときは光学フロー）
    let interpolation: FrameInterpolation
    let shutter: Double
    /// 同じ結果になる条件をまとめた文字列（キャッシュの名前に使う）
    let signature: String

    /// 作ったファイルの置き場所（素材フォルダーからの相対パス）。同じ条件なら同じ名前になるので、元に戻したときもそのまま使える。
    var cachePath: String {
        return RetimePlan.folder + "/" + RetimePlan.hexHash(signature) + ".mov"
    }

    /// clip を fps のタイムラインに置いたときの計画。逆再生なら、逆順にした素材ファイルの中の時刻で表す。
    init(clip: Clip, asset: MediaAsset, fps: Double) {
        let frameTicks: Int64 = max(1, Time.frameDuration(fps: fps).ticks)
        let map = SpeedMap(settings: clip.speed)
        let duration: Time = clip.duration
        let sourceLength: Time = map.sourceDuration(forTimeline: duration)
        var base: Time = clip.sourceStart
        if clip.speed.reversed {
            base = max(.zero, asset.duration - clip.sourceStart - sourceLength)
        }
        let shutter: Double = Num.clamp(clip.speed.motionBlur, 0, 1)
        // タイムラインのコマの位置（合成はコマの長さの整数倍の時刻で絵を求める）
        let firstIndex: Int64 = RetimePlan.ceilDiv(clip.start.ticks, frameTicks)
        let halfExposure: Double = shutter * Double(frameTicks) / 2
        var frames: [RetimeFrame] = []
        var index: Int64 = firstIndex
        while true {
            let local: Int64 = index * frameTicks - clip.start.ticks
            if local >= duration.ticks { break }
            let center: Double = RetimePlan.source(at: Double(local), map: map, duration: duration, base: base, length: sourceLength)
            var start: Double = center
            var end: Double = center
            if halfExposure > 0 {
                start = RetimePlan.source(at: Double(local) - halfExposure, map: map, duration: duration, base: base, length: sourceLength)
                end = RetimePlan.source(at: Double(local) + halfExposure, map: map, duration: duration, base: base, length: sourceLength)
            }
            let output: Double = Double(local) / Double(Time.timescale)
            frames.append(RetimeFrame(outputTime: output, sourceTime: center, exposureStart: min(start, end), exposureEnd: max(start, end)))
            index += 1
        }
        self.frames = frames
        self.duration = duration.seconds
        var lowest: Double = base.seconds
        var highest: Double = (base + sourceLength).seconds
        for frame in frames {
            lowest = min(lowest, frame.exposureStart)
            highest = max(highest, frame.exposureEnd)
        }
        self.sourceStart = max(0, lowest)
        self.sourceEnd = highest
        self.fps = fps
        // コマの繰り返しのままモーションブラーだけを付けるときは、ブラーの中のコマを光学フローで作る
        let wanted: FrameInterpolation = clip.speed.interpolation
        self.interpolation = wanted == .sampling && shutter > 0.001 ? .opticalFlow : wanted
        self.shutter = shutter
        self.signature = RetimePlan.signature(clip: clip, asset: asset, fps: fps)
    }

    /// 同じ結果になる条件をまとめた文字列（コマの計算をせずに求める）。
    static func signature(clip: Clip, asset: MediaAsset, fps: Double) -> String {
        let frameTicks: Int64 = max(1, Time.frameDuration(fps: fps).ticks)
        var base: Time = clip.sourceStart
        if clip.speed.reversed {
            let sourceLength: Time = SpeedMap(settings: clip.speed).sourceDuration(forTimeline: clip.duration)
            base = max(.zero, asset.duration - clip.sourceStart - sourceLength)
        }
        let phase: Int64 = ((clip.start.ticks % frameTicks) + frameTicks) % frameTicks
        let shutter: Double = Num.clamp(clip.speed.motionBlur, 0, 1)
        return makeSignature(clip: clip, asset: asset, fps: fps, base: base, phase: phase, shutter: shutter)
    }

    /// 作ったファイルの置き場所（コマの計算をせずに求める）。
    static func cachePath(clip: Clip, asset: MediaAsset, fps: Double) -> String {
        return folder + "/" + hexHash(signature(clip: clip, asset: asset, fps: fps)) + ".mov"
    }

    /// クリップの先頭から local ティック進んだときの素材の時刻（秒）。クリップの外は端の速さのまま伸ばす（ブラー用）。
    private static func source(at local: Double, map: SpeedMap, duration: Time, base: Time, length: Time) -> Double {
        let timescale: Double = Double(Time.timescale)
        if local < 0 {
            return (Double(base.ticks) + local * map.rate(at: 0)) / timescale
        }
        if local > Double(duration.ticks) {
            let over: Double = local - Double(duration.ticks)
            return (Double(base.ticks) + Double(length.ticks) + over * map.rate(at: 1)) / timescale
        }
        let offset: Time = map.sourceOffset(atTimeline: Time(ticks: Int64(local.rounded())), timelineDuration: duration)
        return Double(base.ticks + offset.ticks) / timescale
    }

    private static func ceilDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        if value >= 0 { return (value + divisor - 1) / divisor }
        return -((-value) / divisor)
    }

    private static func makeSignature(clip: Clip, asset: MediaAsset, fps: Double, base: Time, phase: Int64, shutter: Double) -> String {
        var parts: [String] = ["v\(RetimePlan.version)", asset.id.uuidString, "\(asset.duration.ticks)", "\(asset.fileSize)"]
        parts.append(clip.speed.reversed ? "rev" : "fwd")
        parts.append("\(base.ticks)")
        parts.append("\(clip.duration.ticks)")
        parts.append("\(Int((fps * 1000).rounded()))")
        parts.append("\(phase)")
        parts.append(clip.speed.interpolation.rawValue)
        parts.append("\(Int((shutter * 1000).rounded()))")
        if clip.speed.hasCurve {
            for point in SpeedMap.normalized(clip.speed.curve) {
                parts.append("\(Int((point.position * 100_000).rounded())):\(Int((point.rate * 100_000).rounded()))")
            }
        } else {
            parts.append("\(Int((clip.speed.rate * 100_000).rounded()))")
        }
        return parts.joined(separator: "|")
    }

    /// 作る意味があるか。コマの繰り返しで同じ結果になる（どのコマも素材のコマから同じだけずれた所を写し、ブラーもない）なら作らない。
    func isNeeded(sourceFPS: Double) -> Bool {
        if interpolation == .sampling || frames.isEmpty { return false }
        if shutter > 0.001 { return true }
        let rate: Double = sourceFPS > 0 ? sourceFPS : 30
        let first: Double = frames[0].sourceTime * rate
        let offset: Double = first - first.rounded(.down)
        for frame in frames {
            let position: Double = frame.sourceTime * rate - offset
            if abs(position - position.rounded()) > 0.02 { return true }
        }
        return false
    }

    /// 文字列の指紋（FNV-1a 64 ビット、16 進 16 桁）。
    static func hexHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits: String = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 16 - digits.count)) + digits
    }
}

/// スムースカット（光学フローのトランジション）で作る短い動画の計画。切れ目をはさむ区間で、A から B へ変形させる（Premiere の Morph Cut と同じ考え方）。
/// 作ったファイルはトランジションの区間（切れ目 − half 〜 切れ目 + half）のタイムラインのコマと 1 対 1 に対応する。
struct SmoothCutPlan: Equatable, Sendable {
    static let version: Int = 1

    /// 区間の始まり（タイムライン）
    let windowStart: Time
    let duration: Time
    /// 作るファイルの中の各コマの時刻（秒）と、変形の進み（0〜1）
    let outputTimes: [Double]
    let progress: [Double]
    /// 区間の始まりで A が写すコマ・区間の終わりで B が写すコマ（それぞれの素材ファイルの中の秒）
    let fromTime: Double
    let toTime: Double
    let fps: Double
    let signature: String

    var cachePath: String {
        return RetimePlan.folder + "/morph-" + RetimePlan.hexHash(signature) + ".mov"
    }

    /// a の次に b があり、b にスムースカットが付いているとき。逆再生のクリップでは作らない。
    init?(from a: Clip, to b: Clip, assetA: MediaAsset, assetB: MediaAsset, fps: Double) {
        guard let transition = b.transitionIn, transition.kind == .smoothCut, a.end == b.start,
              a.kind == .video, b.kind == .video, !a.speed.reversed, !b.speed.reversed else { return nil }
        let limit: Int64 = min(transition.duration.ticks, min(a.duration.ticks, b.duration.ticks))
        let half: Int64 = limit / 2
        if half <= 0 { return nil }
        let frameTicks: Int64 = max(1, Time.frameDuration(fps: fps).ticks)
        let start: Int64 = b.start.ticks - half
        let length: Int64 = half * 2
        var times: [Double] = []
        var steps: [Double] = []
        var index: Int64 = start >= 0 ? (start + frameTicks - 1) / frameTicks : -((-start) / frameTicks)
        while index * frameTicks < start + length {
            let local: Int64 = index * frameTicks - start
            if local >= 0 {
                times.append(Double(local) / Double(Time.timescale))
                // 両端でゆっくり、真ん中で速く変える
                let p: Double = Num.clamp((Double(local) + Double(frameTicks) / 2) / Double(length), 0, 1)
                steps.append(p * p * (3 - 2 * p))
            }
            index += 1
        }
        if times.isEmpty { return nil }
        // 区間の端で絵が飛ばないよう、区間の始まりで A が写すコマから、区間の終わりで B が写すコマへ変形させる
        let mapA = SpeedMap(settings: a.speed)
        let mapB = SpeedMap(settings: b.speed)
        let offsetA: Time = mapA.sourceOffset(atTimeline: a.duration - Time(ticks: half), timelineDuration: a.duration)
        let offsetB: Time = mapB.sourceOffset(atTimeline: Time(ticks: half), timelineDuration: b.duration)
        let fromTime: Double = (a.sourceStart + offsetA).seconds
        let toTime: Double = (b.sourceStart + offsetB).seconds
        self.windowStart = Time(ticks: start)
        self.duration = Time(ticks: length)
        self.outputTimes = times
        self.progress = steps
        self.fromTime = fromTime
        self.toTime = toTime
        self.fps = fps
        let phase: Int64 = ((start % frameTicks) + frameTicks) % frameTicks
        var parts: [String] = ["m\(SmoothCutPlan.version)", assetA.id.uuidString, assetB.id.uuidString]
        parts.append("\(Int((fromTime * 60_000).rounded()))")
        parts.append("\(Int((toTime * 60_000).rounded()))")
        parts.append("\(length)")
        parts.append("\(phase)")
        parts.append("\(Int((fps * 1000).rounded()))")
        self.signature = parts.joined(separator: "|")
    }

    /// プロジェクトのメイントラックにあるスムースカットの計画（a の id と b の id、素材）。
    static func all(in project: Project, fps: Double) -> [(from: Clip, to: Clip, plan: SmoothCutPlan)] {
        guard let main = project.mainTrackIndex else { return [] }
        let clips: [Clip] = project.tracks[main].clips
        var result: [(from: Clip, to: Clip, plan: SmoothCutPlan)] = []
        if clips.count < 2 { return result }
        for i in 1..<clips.count {
            let a: Clip = clips[i - 1]
            let b: Clip = clips[i]
            guard b.transitionIn?.kind == .smoothCut, let assetA = project.asset(a.mediaID), let assetB = project.asset(b.mediaID),
                  let plan = SmoothCutPlan(from: a, to: b, assetA: assetA, assetB: assetB, fps: fps) else { continue }
            result.append((a, b, plan))
        }
        return result
    }
}

/// 素材の中の、隣り合う 2 コマとその間の位置。
struct FramePair: Equatable, Sendable {
    var first: Int
    var second: Int
    /// 0 なら first、1 なら second
    var position: Double
}

enum FrameTiming {
    /// times（昇順）のどの 2 コマの間に time があるか。範囲の外なら端のコマ。
    static func pair(for time: Double, in times: [Double]) -> FramePair {
        guard let first = times.first else { return FramePair(first: 0, second: 0, position: 0) }
        if times.count == 1 || time < first { return FramePair(first: 0, second: 0, position: 0) }
        let last: Int = times.count - 1
        if time >= times[last] { return FramePair(first: last, second: last, position: 0) }
        var low: Int = 0
        var high: Int = last
        while high - low > 1 {
            let middle: Int = (low + high) / 2
            if times[middle] <= time { low = middle } else { high = middle }
        }
        let span: Double = times[high] - times[low]
        let position: Double = span > 0 ? (time - times[low]) / span : 0
        return FramePair(first: low, second: high, position: Num.clamp(position, 0, 1))
    }

    /// シャッターの開いている範囲を、隣り合う 2 コマごとの区間に分ける（モーションブラー用）。
    /// 戻り値の weight の合計は 1。区間の中の位置は from〜to（0〜1）。
    static func segments(from start: Double, to end: Double, in times: [Double]) -> [ExposureSegment] {
        if end - start <= 1e-9 || times.count < 2 {
            let p: FramePair = pair(for: start, in: times)
            return [ExposureSegment(first: p.first, second: p.second, from: p.position, to: p.position, weight: 1)]
        }
        var result: [ExposureSegment] = []
        let total: Double = end - start
        let last: Int = times.count - 1
        var cursor: Double = start
        while cursor < end - 1e-9 {
            // 素材の外は端のコマで埋める
            if cursor < times[0] {
                let until: Double = min(end, times[0])
                result.append(ExposureSegment(first: 0, second: 0, from: 0, to: 0, weight: (until - cursor) / total))
                cursor = until
                continue
            }
            if cursor >= times[last] {
                result.append(ExposureSegment(first: last, second: last, from: 0, to: 0, weight: (end - cursor) / total))
                break
            }
            let p: FramePair = pair(for: cursor, in: times)
            let segmentEnd: Double = min(end, times[p.second])
            if segmentEnd <= cursor {
                // 同じ時刻のコマが続くときなど、進めないときは残りをそのコマで埋める
                result.append(ExposureSegment(first: p.first, second: p.first, from: 0, to: 0, weight: (end - cursor) / total))
                break
            }
            let span: Double = times[p.second] - times[p.first]
            let from: Double = Num.clamp((cursor - times[p.first]) / span, 0, 1)
            let to: Double = Num.clamp((segmentEnd - times[p.first]) / span, 0, 1)
            result.append(ExposureSegment(first: p.first, second: p.second, from: from, to: to, weight: (segmentEnd - cursor) / total))
            cursor = segmentEnd
        }
        return result
    }
}

/// シャッターの開いている間のうち、隣り合う 2 コマの間に入る部分。
struct ExposureSegment: Equatable, Sendable {
    var first: Int
    var second: Int
    var from: Double
    var to: Double
    var weight: Double
}

/// 場面の切り替わり（カット）の判定。カットの前後でコマの間を作ると 2 つの場面が溶けて崩れるので、近いコマをそのまま使う。
/// 明るさをそろえた小さな縮小画像どうしの差と、明るさの分布（ヒストグラム）の差を見る。フェードや明るさの変化はカットとみなさない。
struct CutSignature: Equatable, Sendable {
    static let columns: Int = 32
    static let rows: Int = 18

    /// 縮小画像そのもの（0〜255）
    let values: [Float]
    /// 平均 0・標準偏差 1 にそろえた縮小画像（columns × rows）
    let cells: [Float]
    let mean: Float
    let deviation: Float
    /// 明るさの分布（16 区分。合計 1）
    let histogram: [Float]

    /// 縮小画像（0〜255 の明るさ、columns × rows）から作る。
    init(thumbnail: [Float]) {
        let count: Int = max(1, thumbnail.count)
        var sum: Float = 0
        for v in thumbnail { sum += v }
        let mean: Float = sum / Float(count)
        var variance: Float = 0
        for v in thumbnail {
            let d: Float = v - mean
            variance += d * d
        }
        let deviation: Float = (variance / Float(count)).squareRoot()
        let scale: Float = deviation > 0.5 ? 1 / deviation : 0
        var cells: [Float] = []
        cells.reserveCapacity(thumbnail.count)
        var histogram: [Float] = Array(repeating: 0, count: 16)
        for v in thumbnail {
            cells.append((v - mean) * scale)
            let bin: Int = max(0, min(15, Int(v / 16)))
            histogram[bin] += 1 / Float(count)
        }
        self.values = thumbnail
        self.cells = cells
        self.mean = mean
        self.deviation = deviation
        self.histogram = histogram
    }

    /// 明るさの絵を columns × rows に平均して縮める。
    static func thumbnail(of image: GrayImage) -> [Float] {
        var result: [Float] = Array(repeating: 0, count: columns * rows)
        var counts: [Float] = Array(repeating: 0, count: columns * rows)
        for y in 0..<image.height {
            let row: Int = min(rows - 1, y * rows / max(1, image.height))
            for x in 0..<image.width {
                let column: Int = min(columns - 1, x * columns / max(1, image.width))
                let cell: Int = row * columns + column
                result[cell] += image.pixels[y * image.width + x]
                counts[cell] += 1
            }
        }
        for i in 0..<result.count where counts[i] > 0 {
            result[i] /= counts[i]
        }
        return result
    }
}

struct SceneCutDetector: Sendable {
    /// 直前の 2 コマの差（動きの大きい場面で誤ってカットと判定しないように比べる）
    private(set) var previousDifference: Double?

    init() {}

    /// 縮小画像どうしの差（0 = 同じ。無関係な絵だと 1.1 前後）。
    static func difference(_ a: CutSignature, _ b: CutSignature) -> Double {
        let count: Int = min(a.cells.count, b.cells.count)
        if count == 0 { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            sum += abs(a.cells[i] - b.cells[i])
        }
        return Double(sum / Float(count))
    }

    /// 明るさの分布の差（0〜1）。
    static func histogramDistance(_ a: CutSignature, _ b: CutSignature) -> Double {
        var sum: Float = 0
        for i in 0..<min(a.histogram.count, b.histogram.count) {
            sum += abs(a.histogram[i] - b.histogram[i])
        }
        return Double(sum / 2)
    }

    /// ほぼ同じ絵か（止まっている場面。間のコマを作らずにそのまま使える）。
    /// ゆっくりした動きを止めてしまわないよう、縮小画像のどの区画も明るさが 0.75 以内の差のときだけ。
    static func isStill(_ a: CutSignature, _ b: CutSignature) -> Bool {
        let count: Int = min(a.values.count, b.values.count)
        if count == 0 || a.values.count != b.values.count { return false }
        for i in 0..<count where abs(a.values[i] - b.values[i]) > 0.75 {
            return false
        }
        return true
    }

    /// a の次に b が来たとき、カットか。
    mutating func isCut(_ a: CutSignature, _ b: CutSignature) -> Bool {
        let histogram: Double = SceneCutDetector.histogramDistance(a, b)
        // ほとんど模様のない絵（黒・白・単色）では形を比べられないので、明るさの分布だけで決める
        if a.deviation < 4 || b.deviation < 4 {
            previousDifference = nil
            return histogram > 0.6
        }
        let d: Double = SceneCutDetector.difference(a, b)
        let previous: Double? = previousDifference
        var cut: Bool = false
        if histogram > 0.5 && d > 0.6 {
            // 形も明るさの分布も大きく変わった（フェードや明るさの変化では形が変わらない）
            cut = true
        } else if d > 0.95 {
            cut = previous.map { d > $0 * 1.6 } ?? true
        } else if d > 0.6 && histogram > 0.3 {
            cut = previous.map { d > $0 * 2.5 } ?? true
        }
        // カットの差は覚えない（1 コマだけ別の場面が挟まったときも、その次のカットを見逃さないように）
        if !cut { previousDifference = d }
        return cut
    }
}
