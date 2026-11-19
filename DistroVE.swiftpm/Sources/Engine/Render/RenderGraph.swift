#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import Foundation

/// 合成 1 回分の情報。プロジェクトの最新の値（色やキーフレーム）はここを差し替えるだけで、合成を作り直さずに反映できる。
final class RenderGraph: @unchecked Sendable {
    struct LayerSource {
        let trackID: CMPersistentTrackID
        let orientation: CGImagePropertyOrientation
    }

    struct Snapshot {
        let project: Project
        let beats: [Time]
        let subtitleTracks: [Int]
    }

    private let state: Locked<Snapshot>
    let layerSources: [UUID: LayerSource]
    let renderSize: CGSize
    let renderer: FrameRenderer
    let media: MediaStore

    init(project: Project, layerSources: [UUID: LayerSource], renderSize: CGSize, renderer: FrameRenderer, media: MediaStore) {
        self.state = Locked(RenderGraph.snapshot(project))
        self.layerSources = layerSources
        self.renderSize = renderSize
        self.renderer = renderer
        self.media = media
    }

    var snapshot: Snapshot { return state.get() }

    /// 色・位置・エフェクトなど、時間の並びが変わらない変更を反映する。
    func update(project: Project) {
        state.set(RenderGraph.snapshot(project))
    }

    private static func snapshot(_ project: Project) -> Snapshot {
        return Snapshot(project: project, beats: project.beatTimes, subtitleTracks: project.trackIndices(of: .subtitle))
    }

    /// 動画の向き（回転情報）から Core Image の向きを決める。
    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { return abs(a - b) < 0.01 }
        if near(t.a, 0) && near(t.b, 1) && near(t.c, -1) && near(t.d, 0) { return .right }
        if near(t.a, 0) && near(t.b, -1) && near(t.c, 1) && near(t.d, 0) { return .left }
        if near(t.a, -1) && near(t.b, 0) && near(t.c, 0) && near(t.d, -1) { return .down }
        return .up
    }
}

/// 合成の命令 1 区間分（AVFoundation の独自合成に渡す）。
final class DistroInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let trackIDs: [CMPersistentTrackID]
    let graph: RenderGraph

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], graph: RenderGraph) {
        self.timeRange = timeRange
        self.trackIDs = trackIDs
        var ids: [NSValue] = []
        for id in trackIDs {
            ids.append(NSNumber(value: id))
        }
        self.requiredSourceTrackIDs = ids
        self.graph = graph
        super.init()
    }
}

/// 独自の合成処理。AVPlayer（プレビュー）と書き出しの両方から毎フレーム呼ばれ、Core Image（Metal）で 1 枚を作る。
final class DistroCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.distrove.compositor", qos: .userInitiated)
    private let generation = Locked<Int>(0)

    #if compiler(>=6.0)
    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    #else
    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: String](),
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    #endif

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    }

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        let request: AVAsynchronousVideoCompositionRequest = asyncVideoCompositionRequest
        let ticket: Int = generation.get()
        queue.async {
            if ticket != self.generation.get() {
                request.finishCancelledRequest()
                return
            }
            self.render(request)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        generation.update { $0 += 1 }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? DistroInstruction else {
                request.finish(with: EngineError.unsupported("合成の命令が読めません"))
                return
            }
            guard let output = request.renderContext.newPixelBuffer() else {
                request.finish(with: EngineError.exportFailed("描画先を確保できません"))
                return
            }
            var frames: [CMPersistentTrackID: CVPixelBuffer] = [:]
            for id in instruction.trackIDs {
                if let buffer = request.sourceFrame(byTrackID: id) {
                    frames[id] = buffer
                }
            }
            let graph: RenderGraph = instruction.graph
            let size: CGSize = request.renderContext.size
            let image: CIImage = graph.renderer.renderFrame(graph: graph, time: Time(request.compositionTime), sources: frames, size: size)
            graph.renderer.render(image, to: output, size: size)
            request.finish(withComposedVideoFrame: output)
        }
    }
}
#endif
