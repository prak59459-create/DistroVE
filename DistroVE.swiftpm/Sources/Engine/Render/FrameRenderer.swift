#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import Foundation
import Metal

/// 1 フレームを組み立てる。下のトラックから順に、クリップごとに 素材 → 色 → マスク → 配置 → エフェクト → 重ね合わせ の順で処理する。
final class FrameRenderer: @unchecked Sendable {
    static let shared = FrameRenderer()

    let context: CIContext
    let colors = ColorPipeline()
    let stills = StillImageCache()
    let texts = TextRasterizer()
    let shapes = ShapeRasterizer()
    let segmenter = PersonSegmenter()
    let outputColorSpace: CGColorSpace
    let usesGPU: Bool

    init() {
        outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
            usesGPU = true
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
            usesGPU = false
        }
    }

    func render(_ image: CIImage, to buffer: CVPixelBuffer, size: CGSize) {
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: outputColorSpace)
    }

    func clearCaches() {
        colors.clear()
        stills.clear()
        texts.clear()
    }

    // MARK: フレーム

    func renderFrame(graph: RenderGraph, time t: Time, sources: [CMPersistentTrackID: CVPixelBuffer], size: CGSize) -> CIImage {
        let snapshot: RenderGraph.Snapshot = graph.snapshot
        let project: Project = snapshot.project
        let canvas = CGRect(origin: .zero, size: size)
        let context = LayerContext(canvas: canvas, unit: min(size.width, size.height) / 1080, beats: snapshot.beats,
                                   sources: sources, graph: graph, project: project)
        var acc: CIImage = CIImage(color: project.canvas.background.ciColor).cropped(to: canvas)
        let background: CIImage = acc
        for index in project.trackIndices(of: .video) {
            let track: Track = project.tracks[index]
            if track.isHidden { continue }
            if index == project.mainTrackIndex, let tr = activeTransition(track, at: t) {
                let a: CIImage = layerOver(tr.from, background: background, at: t, context: context)
                let b: CIImage = layerOver(tr.to, background: background, at: t, context: context)
                acc = EffectRenderer.transition(tr.kind, from: a, to: b, progress: tr.progress, canvas: canvas, unit: context.unit)
                continue
            }
            guard let clip = FrameRenderer.clip(in: track, at: t) else { continue }
            if clip.kind == .adjustment {
                acc = adjustment(clip, base: acc, at: t, context: context)
                continue
            }
            if let layer = layer(clip, at: t, context: context) {
                acc = FrameRenderer.blend(layer, over: acc, mode: clip.blend)
            }
        }
        for index in snapshot.subtitleTracks {
            let track: Track = project.tracks[index]
            if track.isHidden { continue }
            if let image = subtitle(track, at: t, context: context) {
                acc = image.composited(over: acc)
            }
        }
        return acc.cropped(to: canvas)
    }

    struct LayerContext {
        let canvas: CGRect
        let unit: CGFloat
        let beats: [Time]
        let sources: [CMPersistentTrackID: CVPixelBuffer]
        let graph: RenderGraph
        let project: Project
    }

    struct ActiveTransition {
        let from: Clip
        let to: Clip
        let kind: TransitionKind
        let progress: Double
    }

    /// 二分探索で time を含むクリップを探す。
    static func clip(in track: Track, at time: Time) -> Clip? {
        let clips: [Clip] = track.clips
        var low: Int = 0
        var high: Int = clips.count - 1
        while low <= high {
            let mid: Int = (low + high) / 2
            let c: Clip = clips[mid]
            if time < c.start {
                high = mid - 1
            } else if time >= c.end {
                low = mid + 1
            } else {
                return c
            }
        }
        return nil
    }

    static func transitionHalf(_ transition: ClipTransition, _ a: Clip, _ b: Clip) -> Time {
        let limit: Int64 = min(a.duration.ticks, b.duration.ticks)
        return Time(ticks: min(transition.duration.ticks, limit) / 2)
    }

    /// メイントラックで、切れ目をまたぐトランジション中か。
    func activeTransition(_ track: Track, at t: Time) -> ActiveTransition? {
        let clips: [Clip] = track.clips
        guard let index = clips.firstIndex(where: { t >= $0.start && t < $0.end }) else { return nil }
        if index + 1 < clips.count {
            let a: Clip = clips[index]
            let b: Clip = clips[index + 1]
            if let tr = b.transitionIn, b.start == a.end {
                let half: Time = FrameRenderer.transitionHalf(tr, a, b)
                if half.isPositive && t >= b.start - half {
                    let p: Double = Double((t - (b.start - half)).ticks) / Double(half.ticks * 2)
                    return ActiveTransition(from: a, to: b, kind: tr.kind, progress: p)
                }
            }
        }
        if index > 0 {
            let a: Clip = clips[index - 1]
            let b: Clip = clips[index]
            if let tr = b.transitionIn, b.start == a.end {
                let half: Time = FrameRenderer.transitionHalf(tr, a, b)
                if half.isPositive && t < b.start + half {
                    let p: Double = Double((t - (b.start - half)).ticks) / Double(half.ticks * 2)
                    return ActiveTransition(from: a, to: b, kind: tr.kind, progress: p)
                }
            }
        }
        return nil
    }

    private func layerOver(_ clip: Clip, background: CIImage, at t: Time, context: LayerContext) -> CIImage {
        guard let layer = layer(clip, at: t, context: context) else { return background }
        return FrameRenderer.blend(layer, over: background, mode: clip.blend).cropped(to: context.canvas)
    }

    // MARK: 重ね合わせ

    static func blend(_ top: CIImage, over bottom: CIImage, mode: LayerBlend) -> CIImage {
        let name: String
        switch mode {
        case .normal: return top.composited(over: bottom)
        case .multiply: name = "CIMultiplyBlendMode"
        case .screen: name = "CIScreenBlendMode"
        case .overlay: name = "CIOverlayBlendMode"
        case .darken: name = "CIDarkenBlendMode"
        case .lighten: name = "CILightenBlendMode"
        case .colorDodge: name = "CIColorDodgeBlendMode"
        case .colorBurn: name = "CIColorBurnBlendMode"
        case .softLight: name = "CISoftLightBlendMode"
        case .hardLight: name = "CIHardLightBlendMode"
        case .difference: name = "CIDifferenceBlendMode"
        case .exclusion: name = "CIExclusionBlendMode"
        case .add: name = "CIAdditionCompositing"
        case .hue: name = "CIHueBlendMode"
        case .saturation: name = "CISaturationBlendMode"
        case .color: name = "CIColorBlendMode"
        case .luminosity: name = "CILuminosityBlendMode"
        }
        return top.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: bottom])
    }

    // MARK: クリップ 1 枚

    func layer(_ clip: Clip, at t: Time, context: LayerContext) -> CIImage? {
        let local: Time = clip.localTime(t)
        let canvas: CGRect = context.canvas
        switch clip.kind {
        case .text, .sticker:
            guard let text = clip.text else { return nil }
            return textLayer(clip, text: text, local: local, timeline: t, context: context)
        case .shape:
            guard let shape = clip.shape else { return nil }
            let box: CGFloat = CGFloat(shape.size) * min(canvas.width, canvas.height)
            guard let image = shapes.image(shape, boxHeight: box) else { return nil }
            return finish(clip, content: image, natural: true, local: local, timeline: t, context: context)
        case .solid:
            let color: RGBA = clip.solidColor ?? .black
            let image: CIImage = CIImage(color: color.ciColor).cropped(to: canvas)
            return finish(clip, content: image, natural: true, local: local, timeline: t, context: context)
        case .audio, .adjustment:
            return nil
        case .video, .image, .gif:
            guard var image = source(clip, local: local, context: context) else { return nil }
            image = FrameRenderer.normalized(image)
            image = sourceAdjustments(clip, image: image, local: local)
            return finish(clip, content: image, natural: false, local: local, timeline: t, context: context)
        }
    }

    /// 素材の映像（動画のフレーム・画像・GIF）。
    private func source(_ clip: Clip, local: Time, context: LayerContext) -> CIImage? {
        switch clip.kind {
        case .video:
            guard let source = context.graph.layerSources[clip.id], let buffer = context.sources[source.trackID] else { return nil }
            return CIImage(cvPixelBuffer: buffer).oriented(source.orientation)
        case .image, .gif:
            guard let asset = context.project.asset(clip.mediaID), let url = context.graph.media.url(for: asset) else { return nil }
            let longSide: CGFloat = max(context.canvas.width, context.canvas.height)
            let maxPixel: Int = Int(min(4096, longSide * 1.5))
            if clip.kind == .gif {
                return stills.gifFrame(url: url, at: local.seconds, maxPixel: maxPixel)
            }
            return stills.image(url: url, maxPixel: maxPixel)
        default:
            return nil
        }
    }

    static func normalized(_ image: CIImage) -> CIImage {
        let e: CGRect = image.extent
        if e.origin == .zero { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
    }

    /// 素材の座標でかける処理（手ぶれ補正・背景除去・クロマキー・切り抜き・マスク・色）。
    private func sourceAdjustments(_ clip: Clip, image input: CIImage, local: Time) -> CIImage {
        var image: CIImage = input
        let extent: CGRect = image.extent
        if let stab = clip.stabilization {
            let sourceTime: Time = clip.sourceStart + SpeedMap(settings: clip.speed).sourceOffset(atTimeline: local, timelineDuration: clip.duration)
            let offset: Vec2 = stab.offset(atSource: sourceTime)
            let z: CGFloat = CGFloat(stab.zoom)
            let t = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(scaleX: z, y: z))
                .concatenating(CGAffineTransform(translationX: extent.midX + CGFloat(offset.x) * extent.width, y: extent.midY + CGFloat(offset.y) * extent.height))
            image = image.clampedToExtent().transformed(by: t).cropped(to: extent)
        }
        if clip.removeBackground {
            image = segmenter.cutout(image)
        }
        if let key = clip.chromaKey {
            image = colors.chromaKey(key, image: image)
        }
        let tr: Transform = clip.transform
        if tr.hasCrop {
            let rect = CGRect(x: extent.width * CGFloat(tr.cropLeft),
                              y: extent.height * CGFloat(tr.cropBottom),
                              width: extent.width * CGFloat(max(0.05, 1 - tr.cropLeft - tr.cropRight)),
                              height: extent.height * CGFloat(max(0.05, 1 - tr.cropTop - tr.cropBottom)))
            image = FrameRenderer.normalized(image.cropped(to: rect))
        }
        if let mask = clip.mask {
            image = colors.applyMask(mask, to: image, at: local)
        }
        image = colors.apply(clip: clip, to: image, at: local)
        return image
    }

    // MARK: 配置

    struct AnimationState {
        var dx: Double = 0
        var dy: Double = 0
        var scale: Double = 1
        var rotation: Double = 0
        var opacity: Double = 1
        var blur: Double = 0
    }

    static func animation(_ clip: Clip, local: Time) -> AnimationState {
        var state = AnimationState()
        if let a = clip.animationIn, a.duration.isPositive, local < a.duration {
            let q: Double = Double(local.ticks) / Double(a.duration.ticks)
            applyAnimation(a.kind, remaining: 1 - Easing.easeOut.apply(q), to: &state)
        }
        if let a = clip.animationOut, a.duration.isPositive {
            let left: Time = clip.duration - local
            if left < a.duration {
                let q: Double = Double(left.ticks) / Double(a.duration.ticks)
                applyAnimation(a.kind, remaining: 1 - Easing.easeOut.apply(q), to: &state)
            }
        }
        return state
    }

    static func applyAnimation(_ kind: AnimationKind, remaining r: Double, to s: inout AnimationState) {
        switch kind {
        case .fade:
            s.opacity *= 1 - r
        case .slideLeft:
            s.dx -= r
        case .slideRight:
            s.dx += r
        case .slideUp:
            s.dy += r
        case .slideDown:
            s.dy -= r
        case .zoom:
            s.scale *= max(0.05, 1 - 0.7 * r)
            s.opacity *= 1 - r
        case .pop:
            let q: Double = 1 - r
            s.scale *= q < 0.6 ? max(0.05, 1.15 * q / 0.6) : 1.15 - 0.15 * (q - 0.6) / 0.4
        case .spin:
            s.rotation += r * 180
            s.scale *= max(0.1, 1 - 0.8 * r)
        case .blur:
            s.blur += r * 30
            s.opacity *= 1 - r * 0.5
        }
    }

    /// テキストの動き（Q46）。
    static func textAnimation(_ text: TextContent, local: Time, timeline: Time, into s: inout AnimationState) -> Int? {
        let d: Double = max(0.05, text.animationDuration)
        let t: Double = local.seconds
        let p: Double = Num.clamp(t / d, 0, 1)
        switch text.animation {
        case .none:
            return nil
        case .fade:
            s.opacity *= Easing.easeOut.apply(p)
        case .typewriter:
            let count: Int = text.string.count
            let total: Double = max(d, Double(count) * 0.06)
            return Int((Double(count) * Num.clamp(t / total, 0, 1)).rounded(.up))
        case .pop:
            s.scale *= p < 0.6 ? max(0.05, 1.18 * p / 0.6) : 1.18 - 0.18 * (p - 0.6) / 0.4
        case .slideUp:
            s.dy += (1 - Easing.easeOut.apply(p)) * 0.08
            s.opacity *= Easing.easeOut.apply(p)
        case .bounce:
            let k: Double = exp(-4 * t) * sin(t * 14)
            s.scale *= 1 + 0.25 * k
        case .glitch:
            let seed: Int = Int(timeline.seconds * 12)
            if t < d || Num.hash01(seed) > 0.85 {
                s.dx += (Num.hash01(seed * 5) - 0.5) * 0.02
                s.dy += (Num.hash01(seed * 7) - 0.5) * 0.01
            }
        case .blurIn:
            s.blur += (1 - p) * 25
            s.opacity *= p
        }
        return nil
    }

    private func textLayer(_ clip: Clip, text: TextContent, local: Time, timeline: Time, context: LayerContext) -> CIImage? {
        let canvas: CGRect = context.canvas
        var extra = AnimationState()
        let visible: Int? = FrameRenderer.textAnimation(text, local: local, timeline: timeline, into: &extra)
        if let v = visible, v <= 0 { return nil }
        let fontPixels: CGFloat = max(4, CGFloat(text.size) * canvas.height)
        let maxWidth: CGFloat = CGFloat(text.maxWidth) * canvas.width
        guard let image = texts.image(text, fontPixels: fontPixels, maxWidth: maxWidth, visibleCharacters: visible) else { return nil }
        var placed: CIImage? = finish(clip, content: image, natural: true, local: local, timeline: timeline, context: context, extra: extra)
        if text.animation == .glitch, let p = placed {
            let seed: Int = Int(timeline.seconds * 12)
            if local.seconds < text.animationDuration || Num.hash01(seed) > 0.85 {
                placed = EffectRenderer.rgbSplit(p, offset: 6 * context.unit, bounds: canvas)
            }
        }
        return placed
    }

    /// 配置（収め方・位置・大きさ・回転・3D・出入りの動き）→ エフェクト → 不透明度。
    private func finish(_ clip: Clip, content: CIImage, natural: Bool, local: Time, timeline: Time,
                        context: LayerContext, extra: AnimationState = AnimationState()) -> CIImage? {
        let canvas: CGRect = context.canvas
        let w: CGFloat = max(1, content.extent.width)
        let h: CGFloat = max(1, content.extent.height)
        var sx: CGFloat = 1
        var sy: CGFloat = 1
        if !natural {
            switch clip.fitMode {
            case .fit:
                let s: CGFloat = min(canvas.width / w, canvas.height / h)
                sx = s
                sy = s
            case .fill:
                let s: CGFloat = max(canvas.width / w, canvas.height / h)
                sx = s
                sy = s
            case .stretch:
                sx = canvas.width / w
                sy = canvas.height / h
            }
        }
        var anim: AnimationState = FrameRenderer.animation(clip, local: local)
        anim.dx += extra.dx
        anim.dy += extra.dy
        anim.scale *= extra.scale
        anim.rotation += extra.rotation
        anim.opacity *= extra.opacity
        anim.blur += extra.blur
        let motion: EffectRenderer.MotionOffset = EffectRenderer.motion(clip.effects, local: local, timeline: timeline, beats: context.beats)
        let tr: Transform = clip.transform
        let userScale: CGFloat = CGFloat(tr.scale.value(at: local) * anim.scale * motion.scale)
        sx *= userScale * (tr.flipHorizontal ? -1 : 1)
        sy *= userScale * (tr.flipVertical ? -1 : 1)
        let degrees: Double = tr.rotation.value(at: local) + anim.rotation + motion.rotation
        let radians: CGFloat = -CGFloat(degrees * Double.pi / 180)
        let px: CGFloat = CGFloat(tr.positionX.value(at: local) + anim.dx + motion.dx) * canvas.width
        let py: CGFloat = CGFloat(tr.positionY.value(at: local) + anim.dy + motion.dy) * canvas.height
        let centerX: CGFloat = canvas.midX + px
        let centerY: CGFloat = canvas.midY - py
        let placement = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(rotationAngle: radians))
            .concatenating(CGAffineTransform(translationX: centerX, y: centerY))
        var image: CIImage = FrameRenderer.normalized(content).transformed(by: placement)
        let rx: Double = tr.rotationX.value(at: local)
        let ry: Double = tr.rotationY.value(at: local)
        if abs(rx) > 0.05 || abs(ry) > 0.05 {
            image = EffectRenderer.perspective(image, rotationX: rx * Double.pi / 180, rotationY: ry * Double.pi / 180,
                                               pivot: CGPoint(x: centerX, y: centerY))
        }
        if anim.blur > 0.1 {
            image = image.applyingGaussianBlur(sigma: anim.blur * Double(context.unit))
        }
        image = image.cropped(to: canvas)
        if image.extent.isEmpty { return nil }
        if !clip.effects.isEmpty {
            image = EffectRenderer.apply(clip.effects, to: image, canvas: canvas, local: local, timeline: timeline,
                                         beats: context.beats, unit: context.unit, clipStart: clip.start)
        }
        let alpha: Double = Num.clamp(tr.opacity.value(at: local) * anim.opacity, 0, 1)
        if alpha < 0.999 {
            if alpha <= 0.001 { return nil }
            image = image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
        }
        return image
    }

    // MARK: 調整クリップ・字幕

    /// 調整クリップ：下にある映像全体（またはマスクの範囲）に色とエフェクトをかける。モザイク枠もこれ。
    private func adjustment(_ clip: Clip, base: CIImage, at t: Time, context: LayerContext) -> CIImage {
        let local: Time = clip.localTime(t)
        let canvas: CGRect = context.canvas
        var adjusted: CIImage = colors.apply(clip: clip, to: base, at: local)
        adjusted = EffectRenderer.apply(clip.effects, to: adjusted, canvas: canvas, local: local, timeline: t,
                                        beats: context.beats, unit: context.unit, clipStart: clip.start)
        let opacity: Double = clip.transform.opacity.value(at: local)
        if let mask = clip.mask {
            let maskImage: CIImage = colors.maskImage(mask, extent: canvas, at: local)
            adjusted = adjusted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: base,
                kCIInputMaskImageKey: maskImage
            ])
        }
        if opacity < 0.999 {
            adjusted = EffectRenderer.dissolve(base, adjusted, opacity, canvas)
        }
        return adjusted.cropped(to: canvas)
    }

    private func subtitle(_ track: Track, at t: Time, context: LayerContext) -> CIImage? {
        let shifted: Time = t - track.subtitleOffset
        guard let cue = track.cues.first(where: { shifted >= $0.start && shifted < $0.end }) else { return nil }
        let canvas: CGRect = context.canvas
        let style: SubtitleStyle = track.subtitleStyle
        let text: TextContent = style.textContent(for: cue)
        var anim = AnimationState()
        let visible: Int? = FrameRenderer.textAnimation(text, local: shifted - cue.start, timeline: t, into: &anim)
        if let v = visible, v <= 0 { return nil }
        let fontPixels: CGFloat = max(4, CGFloat(style.size) * canvas.height)
        guard let image = texts.image(text, fontPixels: fontPixels, maxWidth: CGFloat(text.maxWidth) * canvas.width, visibleCharacters: visible) else { return nil }
        let w: CGFloat = image.extent.width
        let h: CGFloat = image.extent.height
        let y: CGFloat = CGFloat(style.bottomMargin) * canvas.height + h / 2 - CGFloat(anim.dy) * canvas.height
        let s: CGFloat = CGFloat(anim.scale)
        let t1 = CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: canvas.midX, y: y))
        var placed: CIImage = FrameRenderer.normalized(image).transformed(by: t1)
        if anim.opacity < 0.999 {
            placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, anim.opacity)))])
        }
        return placed.cropped(to: canvas)
    }
}
#endif
