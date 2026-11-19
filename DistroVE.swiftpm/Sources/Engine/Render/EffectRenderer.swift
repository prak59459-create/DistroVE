#if canImport(AVFoundation)
import CoreImage
import Foundation

/// 映像エフェクト・トランジション・3D 変形（Q36, Q42, Q50）。
/// 大きさの単位はキャンバス高さ 1080px を基準にし、プレビューの縮小表示でも見た目をそろえる。
enum EffectRenderer {
    /// ビートからの経過で決まる 0〜1 の脈（ビート直後に 1、すぐに減衰）。
    static func beatPulse(beats: [Time], at t: Time, decay: Double = 0.18) -> Double {
        if beats.isEmpty { return 0 }
        var low: Int = 0
        var high: Int = beats.count - 1
        if t < beats[0] { return 0 }
        while low < high {
            let mid: Int = (low + high + 1) / 2
            if beats[mid] <= t {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let dt: Double = (t - beats[low]).seconds
        return exp(-dt / decay)
    }

    /// エフェクトの強さ（ビート同期なら脈を掛ける）。
    static func strength(_ effect: VideoEffect, spec: ParamSpec, local: Time, timeline: Time, beats: [Time]) -> Double {
        let base: Double = effect.value(spec, at: local)
        if effect.beatSync && !beats.isEmpty {
            return base * beatPulse(beats: beats, at: timeline)
        }
        return base
    }

    /// 位置・大きさに作用するエフェクト（シェイク・ズームパルス）の量。
    struct MotionOffset {
        var dx: Double = 0
        var dy: Double = 0
        var scale: Double = 1
        var rotation: Double = 0
    }

    static func motion(_ effects: [VideoEffect], local: Time, timeline: Time, beats: [Time]) -> MotionOffset {
        var m = MotionOffset()
        for e in effects where e.isEnabled {
            switch e.kind {
            case .shake:
                let k: Double = strength(e, spec: EffectSpecs.intensity, local: local, timeline: timeline, beats: beats)
                if k <= 0.001 { continue }
                let f: Double = e.value(EffectSpecs.frequency, at: local)
                let seed: Int = Int(timeline.seconds * f)
                m.dx += (Num.hash01(seed * 3 + 1) - 0.5) * 0.06 * k
                m.dy += (Num.hash01(seed * 3 + 2) - 0.5) * 0.06 * k
                m.rotation += (Num.hash01(seed * 3 + 3) - 0.5) * 4 * k
                m.scale *= 1 + 0.04 * k
            case .zoomPulse:
                let amount: Double = e.value(EffectSpecs.amount, at: local)
                let pulse: Double
                if e.beatSync && !beats.isEmpty {
                    pulse = beatPulse(beats: beats, at: timeline)
                } else {
                    pulse = 0.5 + 0.5 * sin(timeline.seconds * 2 * Double.pi * 2)
                }
                m.scale *= 1 + amount * 0.25 * pulse
            default:
                continue
            }
        }
        return m
    }

    /// 画面上でかけるエフェクト（ぼかし・モザイク・グリッチなど）。image はキャンバス座標。
    static func apply(_ effects: [VideoEffect], to image: CIImage, canvas: CGRect, local: Time, timeline: Time,
                      beats: [Time], unit: CGFloat, clipStart: Time) -> CIImage {
        var out: CIImage = image
        let bounds: CGRect = image.extent.intersection(canvas)
        if bounds.isEmpty { return image }
        for e in effects where e.isEnabled {
            switch e.kind {
            case .blur:
                let r: Double = e.value(EffectSpecs.radius, at: local)
                if r > 0.1 { out = out.clampedToExtent().applyingGaussianBlur(sigma: r * Double(unit)).cropped(to: bounds) }
            case .mosaic:
                let size: Double = max(2, e.value(EffectSpecs.cellSize, at: local) * Double(unit))
                out = out.clampedToExtent().applyingFilter("CIPixellate", parameters: [
                    kCIInputScaleKey: size,
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY)
                ]).cropped(to: bounds)
            case .glitch:
                let k: Double = strength(e, spec: EffectSpecs.intensity, local: local, timeline: timeline, beats: beats)
                let f: Double = e.value(EffectSpecs.frequency, at: local)
                let seed: Int = Int(timeline.seconds * f)
                let active: Bool = e.beatSync ? k > 0.05 : Num.hash01(seed) > 0.45
                if active && k > 0.01 {
                    out = glitch(out, bounds: bounds, amount: k, seed: seed, unit: unit)
                }
            case .rgbSplit:
                let k: Double = strength(e, spec: EffectSpecs.amount, local: local, timeline: timeline, beats: beats)
                if k > 0.005 { out = rgbSplit(out, offset: CGFloat(k) * 24 * unit, bounds: bounds) }
            case .vhs:
                let k: Double = e.value(EffectSpecs.intensity, at: local)
                if k > 0.01 { out = vhs(out, bounds: bounds, amount: k, seed: Int(timeline.seconds * 24), unit: unit) }
            case .vignette:
                let k: Double = e.value(EffectSpecs.intensity, at: local)
                let r: Double = e.value(EffectSpecs.radiusRatio, at: local)
                let radius: CGFloat = CGFloat(r) * min(canvas.width, canvas.height) * 0.6
                out = out.applyingFilter("CIVignetteEffect", parameters: [
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputRadiusKey: radius,
                    kCIInputIntensityKey: k,
                    "inputFalloff": 0.6
                ]).cropped(to: bounds)
            case .flash:
                let base: Double = e.value(EffectSpecs.intensity, at: local)
                var k: Double
                if e.beatSync && !beats.isEmpty {
                    k = base * beatPulse(beats: beats, at: timeline, decay: 0.12)
                } else {
                    k = base * exp(-(timeline - clipStart).seconds / 0.25)
                }
                if k > 0.01 {
                    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(min(1, k)))).cropped(to: bounds)
                    out = white.composited(over: out)
                }
            case .grain:
                let k: Double = e.value(EffectSpecs.intensity, at: local)
                if k > 0.01 { out = grain(out, bounds: bounds, amount: k, seed: Int(timeline.seconds * 24)) }
            case .sharpen:
                let k: Double = e.value(EffectSpecs.intensity, at: local)
                out = out.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": k * 2]).cropped(to: bounds)
            case .bloom:
                let k: Double = e.value(EffectSpecs.intensity, at: local)
                let r: Double = e.value(EffectSpecs.radius, at: local)
                out = out.clampedToExtent().applyingFilter("CIBloom", parameters: [
                    kCIInputRadiusKey: r * Double(unit),
                    kCIInputIntensityKey: k
                ]).cropped(to: bounds)
            case .zoomBlur:
                let k: Double = strength(e, spec: EffectSpecs.amount, local: local, timeline: timeline, beats: beats)
                if k > 0.01 {
                    out = out.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [
                        kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                        "inputAmount": k * 40 * Double(unit)
                    ]).cropped(to: bounds)
                }
            case .mono:
                let k: Double = e.value(EffectSpecs.intensity, at: local)
                out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: max(0, 1 - k)])
            case .invert:
                let k: Double = e.value(EffectSpecs.intensity, at: local)
                let inverted: CIImage = out.applyingFilter("CIColorInvert", parameters: [:])
                out = inverted.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: out,
                    kCIInputTimeKey: 1 - k
                ]).cropped(to: bounds)
            case .posterize:
                let levels: Double = e.value(EffectSpecs.levels, at: local)
                out = out.applyingFilter("CIColorPosterize", parameters: ["inputLevels": levels])
            case .kaleidoscope:
                let count: Double = e.value(EffectSpecs.count, at: local)
                out = out.clampedToExtent().applyingFilter("CIKaleidoscope", parameters: [
                    "inputCount": Int(count.rounded()),
                    kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                    kCIInputAngleKey: timeline.seconds * 0.3
                ]).cropped(to: bounds)
            case .mirror:
                let vertical: Bool = e.value(EffectSpecs.direction, at: local) >= 0.5
                out = mirror(out, bounds: bounds, vertical: vertical)
            case .shake, .zoomPulse:
                continue
            }
        }
        return out
    }

    // MARK: 個別のエフェクト

    static func channel(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
    }

    static func rgbSplit(_ image: CIImage, offset: CGFloat, bounds: CGRect) -> CIImage {
        let red: CIImage = channel(image, r: 1, g: 0, b: 0).transformed(by: CGAffineTransform(translationX: offset, y: 0))
        let green: CIImage = channel(image, r: 0, g: 1, b: 0)
        let blue: CIImage = channel(image, r: 0, g: 0, b: 1).transformed(by: CGAffineTransform(translationX: -offset, y: 0))
        let rg: CIImage = red.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
        let rgb: CIImage = blue.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: rg])
        return rgb.cropped(to: bounds)
    }

    static func glitch(_ image: CIImage, bounds: CGRect, amount: Double, seed: Int, unit: CGFloat) -> CIImage {
        var out: CIImage = rgbSplit(image, offset: CGFloat(amount) * 18 * unit * CGFloat(0.5 + Num.hash01(seed * 7)), bounds: bounds)
        let bands: Int = 7
        let bandHeight: CGFloat = bounds.height / CGFloat(bands)
        for i in 0..<bands {
            let r: Double = Num.hash01(seed * 31 + i)
            if r < 0.55 { continue }
            let shift: CGFloat = CGFloat((Num.hash01(seed * 17 + i * 5) - 0.5) * 0.18 * amount) * bounds.width
            let heightScale: CGFloat = CGFloat(0.3 + Num.hash01(seed * 13 + i))
            let rect = CGRect(x: bounds.minX, y: bounds.minY + CGFloat(i) * bandHeight, width: bounds.width, height: bandHeight * heightScale)
            let band: CIImage = out.cropped(to: rect).transformed(by: CGAffineTransform(translationX: shift, y: 0))
            out = band.composited(over: out)
        }
        return out.cropped(to: bounds)
    }

    static func vhs(_ image: CIImage, bounds: CGRect, amount: Double, seed: Int, unit: CGFloat) -> CIImage {
        var out: CIImage = rgbSplit(image, offset: CGFloat(amount) * 5 * unit, bounds: bounds)
        out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - 0.35 * amount, kCIInputContrastKey: 1 + 0.1 * amount])
        let stripes: CIImage = CIFilter(name: "CIStripesGenerator", parameters: [
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: CGFloat(0.18 * amount)),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            "inputWidth": max(1.5, 2 * Double(unit)),
            "inputSharpness": 0.5
        ])?.outputImage ?? CIImage.empty()
        let horizontal: CIImage = stripes.transformed(by: CGAffineTransform(rotationAngle: CGFloat.pi / 2)).cropped(to: bounds)
        out = horizontal.composited(over: out)
        // ときどき横に大きく乱れる帯
        if Num.hash01(seed) > 0.8 {
            let y: CGFloat = bounds.minY + CGFloat(Num.hash01(seed * 3)) * bounds.height
            let rect = CGRect(x: bounds.minX, y: y, width: bounds.width, height: bounds.height * 0.05)
            let band: CIImage = out.cropped(to: rect).transformed(by: CGAffineTransform(translationX: bounds.width * 0.03 * CGFloat(amount), y: 0))
            out = band.composited(over: out)
        }
        return grain(out, bounds: bounds, amount: amount * 0.5, seed: seed).cropped(to: bounds)
    }

    static func grain(_ image: CIImage, bounds: CGRect, amount: Double, seed: Int) -> CIImage {
        guard let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let shift: CGFloat = CGFloat(Num.hash01(seed) * 1000)
        let mono: CIImage = noise.transformed(by: CGAffineTransform(translationX: shift, y: shift * 0.7))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(0.35 * amount))
            ]).cropped(to: bounds)
        return mono.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: bounds)
    }

    static func mirror(_ image: CIImage, bounds: CGRect, vertical: Bool) -> CIImage {
        if vertical {
            let top = CGRect(x: bounds.minX, y: bounds.midY, width: bounds.width, height: bounds.height / 2)
            let flip = CGAffineTransform(translationX: 0, y: -bounds.midY).concatenating(CGAffineTransform(scaleX: 1, y: -1)).concatenating(CGAffineTransform(translationX: 0, y: bounds.midY))
            return image.cropped(to: top).transformed(by: flip).composited(over: image.cropped(to: top)).cropped(to: bounds)
        }
        let left = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width / 2, height: bounds.height)
        let flip = CGAffineTransform(translationX: -bounds.midX, y: 0).concatenating(CGAffineTransform(scaleX: -1, y: 1)).concatenating(CGAffineTransform(translationX: bounds.midX, y: 0))
        return image.cropped(to: left).transformed(by: flip).composited(over: image.cropped(to: left)).cropped(to: bounds)
    }

    // MARK: 3D

    /// 長方形 rect を X 軸・Y 軸まわりに回したときの 4 隅（遠近あり）。z は奥行きの移動。
    static func perspectiveCorners(_ rect: CGRect, rotationX: Double, rotationY: Double, z: Double = 0,
                                   pivot: CGPoint? = nil, focal: Double) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let center: CGPoint = pivot ?? CGPoint(x: rect.midX, y: rect.midY)
        let corners: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.minY)
        ]
        var out: [CGPoint] = []
        let cosY: Double = cos(rotationY)
        let sinY: Double = sin(rotationY)
        let cosX: Double = cos(rotationX)
        let sinX: Double = sin(rotationX)
        for p in corners {
            let x: Double = Double(p.x - center.x)
            let y: Double = Double(p.y - center.y)
            let x1: Double = x * cosY
            let z1: Double = -x * sinY
            let y2: Double = y * cosX - z1 * sinX
            let z2: Double = y * sinX + z1 * cosX + z
            let depth: Double = max(focal * 0.1, focal + z2)
            let s: Double = focal / depth
            out.append(CGPoint(x: Double(center.x) + x1 * s, y: Double(center.y) + y2 * s))
        }
        return (out[0], out[1], out[2], out[3])
    }

    static func perspective(_ image: CIImage, rotationX: Double, rotationY: Double, z: Double = 0, pivot: CGPoint? = nil) -> CIImage {
        let rect: CGRect = image.extent
        if rect.isEmpty || rect.isInfinite { return image }
        let focal: Double = Double(max(rect.width, rect.height)) * 2
        let c: (CGPoint, CGPoint, CGPoint, CGPoint) = perspectiveCorners(rect, rotationX: rotationX, rotationY: rotationY, z: z, pivot: pivot, focal: focal)
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: c.0),
            "inputTopRight": CIVector(cgPoint: c.1),
            "inputBottomRight": CIVector(cgPoint: c.2),
            "inputBottomLeft": CIVector(cgPoint: c.3)
        ])
    }

    // MARK: トランジション

    /// a から b へ。p は 0〜1。どちらもキャンバス全体の不透明な画像。
    static func transition(_ kind: TransitionKind, from a: CIImage, to b: CIImage, progress p: Double, canvas: CGRect, unit: CGFloat) -> CIImage {
        let q: Double = Num.clamp(p, 0, 1)
        let smooth: Double = q * q * (3 - 2 * q)
        let w: CGFloat = canvas.width
        let h: CGFloat = canvas.height
        switch kind {
        case .fade:
            return dissolve(a, b, q, canvas)
        case .fadeBlack, .flashWhite:
            let color: CIColor = kind == .fadeBlack ? CIColor(red: 0, green: 0, blue: 0) : CIColor(red: 1, green: 1, blue: 1)
            let solid = CIImage(color: color).cropped(to: canvas)
            if q < 0.5 { return dissolve(a, solid, q * 2, canvas) }
            return dissolve(solid, b, (q - 0.5) * 2, canvas)
        case .slideLeft, .slideRight, .slideUp, .slideDown:
            var dx: CGFloat = 0
            var dy: CGFloat = 0
            switch kind {
            case .slideLeft: dx = -w
            case .slideRight: dx = w
            case .slideUp: dy = h
            default: dy = -h
            }
            let k: CGFloat = CGFloat(smooth)
            let movedA: CIImage = a.transformed(by: CGAffineTransform(translationX: dx * k, y: dy * k))
            let movedB: CIImage = b.transformed(by: CGAffineTransform(translationX: -dx * (1 - k), y: -dy * (1 - k)))
            return movedB.composited(over: movedA).cropped(to: canvas)
        case .wipeLeft, .wipeRight, .wipeUp, .wipeDown:
            return wipe(kind, a, b, smooth, canvas, unit: unit)
        case .zoomIn, .zoomOut:
            let zoomIn: Bool = kind == .zoomIn
            let source: CIImage = q < 0.5 ? a : b
            let local: Double = q < 0.5 ? q * 2 : (1 - q) * 2
            let scale: CGFloat = zoomIn ? CGFloat(1 + local * 0.6) : CGFloat(1 / (1 + local * 0.6))
            let t = CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
            var out: CIImage = source.clampedToExtent().transformed(by: t)
            out = out.applyingFilter("CIZoomBlur", parameters: [
                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                "inputAmount": local * 30 * Double(unit)
            ])
            return out.cropped(to: canvas)
        case .blur:
            let sigma: Double = sin(Double.pi * q) * 30 * Double(unit)
            let blurredA: CIImage = a.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: canvas)
            let blurredB: CIImage = b.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: canvas)
            return dissolve(blurredA, blurredB, q, canvas)
        case .glitch:
            let mixed: CIImage = q < 0.5 ? a : b
            return glitch(mixed, bounds: canvas, amount: sin(Double.pi * q), seed: Int(q * 40), unit: unit)
        case .spin:
            let source: CIImage = q < 0.5 ? a : b
            let local: Double = q < 0.5 ? q * 2 : (1 - q) * 2
            let angle: CGFloat = CGFloat((q < 0.5 ? 1 : -1) * local * Double.pi)
            let scale: CGFloat = CGFloat(1 - local * 0.5)
            let t = CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: canvas.midX, y: canvas.midY))
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
            return source.transformed(by: t).composited(over: black).cropped(to: canvas)
        case .flip3D:
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
            if q < 0.5 {
                let angle: Double = smooth * Double.pi
                return perspective(a, rotationX: 0, rotationY: angle).composited(over: black).cropped(to: canvas)
            }
            let angle: Double = (smooth - 1) * Double.pi
            return perspective(b, rotationX: 0, rotationY: angle).composited(over: black).cropped(to: canvas)
        case .cube3D:
            // 立方体を縦の軸で 90 度回す。a は正面から左へ、b は右の面から正面へ
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)
            let angle: Double = smooth * Double.pi / 2
            let faceA: CIImage = mapCorners(a, cubeCorners(faceB: false, angle: angle, canvas: canvas))
            let faceB: CIImage = mapCorners(b, cubeCorners(faceB: true, angle: angle, canvas: canvas))
            return faceB.composited(over: faceA.composited(over: black)).cropped(to: canvas)
        }
    }

    /// 立方体の面の 4 隅（左上・右上・右下・左下、Core Image の上向き座標）。
    static func cubeCorners(faceB: Bool, angle: Double, canvas: CGRect) -> (CGPoint, CGPoint, CGPoint, CGPoint) {
        let w: Double = Double(canvas.width)
        let h: Double = Double(canvas.height)
        let focal: Double = max(w, h) * 2
        let cx: Double = Double(canvas.midX)
        let cy: Double = Double(canvas.midY)
        let corners: [(Double, Double)] = [(-w / 2, h / 2), (w / 2, h / 2), (w / 2, -h / 2), (-w / 2, -h / 2)]
        var out: [CGPoint] = []
        for (u, v) in corners {
            let x: Double = faceB ? w / 2 : u
            let z: Double = faceB ? u : -w / 2
            let x2: Double = x * cos(angle) + z * sin(angle)
            let z2: Double = z * cos(angle) - x * sin(angle)
            let depth: Double = max(focal * 0.1, focal + w / 2 + z2)
            let s: Double = focal / depth
            out.append(CGPoint(x: cx + x2 * s, y: cy + v * s))
        }
        return (out[0], out[1], out[2], out[3])
    }

    static func mapCorners(_ image: CIImage, _ c: (CGPoint, CGPoint, CGPoint, CGPoint)) -> CIImage {
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: c.0),
            "inputTopRight": CIVector(cgPoint: c.1),
            "inputBottomRight": CIVector(cgPoint: c.2),
            "inputBottomLeft": CIVector(cgPoint: c.3)
        ])
    }

    static func dissolve(_ a: CIImage, _ b: CIImage, _ t: Double, _ canvas: CGRect) -> CIImage {
        return a.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: b,
            kCIInputTimeKey: Num.clamp(t, 0, 1)
        ]).cropped(to: canvas)
    }

    static func wipe(_ kind: TransitionKind, _ a: CIImage, _ b: CIImage, _ p: Double, _ canvas: CGRect, unit: CGFloat) -> CIImage {
        let edge: CGFloat = 40 * unit
        var p0 = CGPoint.zero
        var p1 = CGPoint.zero
        let k: CGFloat = CGFloat(p)
        switch kind {
        case .wipeLeft:
            let x: CGFloat = canvas.maxX - (canvas.width + edge * 2) * k + edge
            p0 = CGPoint(x: x + edge, y: 0)
            p1 = CGPoint(x: x - edge, y: 0)
        case .wipeRight:
            let x: CGFloat = canvas.minX + (canvas.width + edge * 2) * k - edge
            p0 = CGPoint(x: x - edge, y: 0)
            p1 = CGPoint(x: x + edge, y: 0)
        case .wipeUp:
            let y: CGFloat = canvas.minY + (canvas.height + edge * 2) * k - edge
            p0 = CGPoint(x: 0, y: y - edge)
            p1 = CGPoint(x: 0, y: y + edge)
        default:
            let y: CGFloat = canvas.maxY - (canvas.height + edge * 2) * k + edge
            p0 = CGPoint(x: 0, y: y + edge)
            p1 = CGPoint(x: 0, y: y - edge)
        }
        let mask: CIImage = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(cgPoint: p0),
            "inputPoint1": CIVector(cgPoint: p1),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0)
        ])?.outputImage?.cropped(to: canvas) ?? CIImage.empty()
        return b.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: a,
            kCIInputMaskImageKey: mask
        ]).cropped(to: canvas)
    }
}
#endif
