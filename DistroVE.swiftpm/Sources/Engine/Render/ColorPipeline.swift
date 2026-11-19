#if canImport(AVFoundation)
import CoreImage
import Foundation

/// 色の調整・LUT・トーンカーブ・クロマキー・マスク（Q41, Q43）。Core Image のフィルターは GPU（Metal）で動く。
final class ColorPipeline: @unchecked Sendable {
    private let cubes = Locked<[String: Data]>([:])
    private let importedLUTs = Locked<[UUID: CubeLUT]>([:])
    private let colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 読み込んだ LUT ファイルの置き場所。
    static var lutFolder: URL {
        return AppPaths.supportFolder("LUTs")
    }

    func registerImported(_ id: UUID, lut: CubeLUT) {
        importedLUTs.update { $0[id] = lut }
    }

    private func importedLUT(_ id: UUID) -> CubeLUT? {
        if let hit = importedLUTs.get()[id] { return hit }
        let url: URL = ColorPipeline.lutFolder.appendingPathComponent(id.uuidString + ".cube")
        guard let text = try? String(contentsOf: url, encoding: .utf8), let lut = try? CubeLUT.parse(text) else { return nil }
        importedLUTs.update { $0[id] = lut }
        return lut
    }

    // MARK: 調整

    func apply(clip: Clip, to image: CIImage, at t: Time) -> CIImage {
        var out: CIImage = image
        out = applyCube(look: clip.look, curves: clip.curves, to: out)
        let c: ParamSet = clip.color
        let exposure: Double = c.value(ColorSpecs.exposure, at: t)
        if abs(exposure) > 0.001 {
            out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": exposure])
        }
        let brightness: Double = c.value(ColorSpecs.brightness, at: t)
        let contrast: Double = c.value(ColorSpecs.contrast, at: t)
        let saturation: Double = c.value(ColorSpecs.saturation, at: t)
        if abs(brightness) > 0.001 || abs(contrast - 1) > 0.001 || abs(saturation - 1) > 0.001 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness,
                kCIInputContrastKey: contrast,
                kCIInputSaturationKey: saturation
            ])
        }
        let vibrance: Double = c.value(ColorSpecs.vibrance, at: t)
        if abs(vibrance) > 0.001 {
            out = out.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance])
        }
        let temperature: Double = c.value(ColorSpecs.temperature, at: t)
        let tint: Double = c.value(ColorSpecs.tint, at: t)
        if abs(temperature) > 0.001 || abs(tint) > 0.001 {
            // 光源の色温度を高く見なすと、補正で暖かい色になる
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: CGFloat(6500 + temperature * 3000), y: CGFloat(tint * 60)),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }
        let highlights: Double = c.value(ColorSpecs.highlights, at: t)
        let shadows: Double = c.value(ColorSpecs.shadows, at: t)
        if abs(highlights - 1) > 0.001 || abs(shadows) > 0.001 {
            out = out.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlights,
                "inputShadowAmount": shadows
            ])
        }
        let hue: Double = c.value(ColorSpecs.hue, at: t)
        if abs(hue) > 0.01 {
            out = out.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: hue * Double.pi / 180])
        }
        let fade: Double = c.value(ColorSpecs.fade, at: t)
        if fade > 0.001 {
            let k: CGFloat = CGFloat(fade * 0.2)
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 - k, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 - k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 - k, w: 0),
                "inputBiasVector": CIVector(x: k, y: k, z: k, w: 0)
            ])
        }
        let sharpen: Double = c.value(ColorSpecs.sharpen, at: t)
        if sharpen > 0.001 {
            out = out.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": sharpen])
        }
        let vignette: Double = c.value(ColorSpecs.vignette, at: t)
        if vignette > 0.001 {
            out = out.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: vignette, kCIInputRadiusKey: 1.2])
        }
        return out.cropped(to: image.extent)
    }

    /// LUT とトーンカーブを 1 枚の変換表にまとめてかける。
    func applyCube(look: LookSettings?, curves: CurveSet?, to image: CIImage) -> CIImage {
        let hasCurves: Bool = curves.map { !$0.isIdentity } ?? false
        if look == nil && !hasCurves { return image }
        let key: String = "\(look?.id ?? "-")|\(Int((look?.intensity ?? 1) * 100))|\(curves?.hashValue ?? 0)"
        var data: Data? = cubes.get()[key]
        var size: Int = 33
        if data == nil {
            var lut: CubeLUT?
            if let look = look {
                if let name = look.builtinName {
                    lut = BuiltinLooks.lut(named: name, size: 25)
                } else if let id = look.lutID {
                    lut = importedLUT(id)
                }
                if let base = lut { lut = base.blended(intensity: look.intensity) }
            }
            let combined: CubeLUT
            if hasCurves {
                combined = CubeLUT.combined(lut: lut, curves: curves, size: 25)
            } else if let only = lut {
                combined = only
            } else {
                return image
            }
            size = combined.size
            let bytes: Data = combined.data.withUnsafeBufferPointer { Data(buffer: $0) }
            data = bytes
            cubes.update { c in
                if c.count > 64 { c.removeAll() }
                c[key] = bytes
            }
        } else if let d = data {
            size = Int(round(pow(Double(d.count / 16), 1.0 / 3.0)))
        }
        guard let cube = data else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": cube,
            "inputColorSpace": colorSpace
        ])
    }

    // MARK: クロマキー

    /// 指定した色の範囲を透明にする（色相との距離で抜く）。
    func chromaKey(_ settings: ChromaKeySettings, image: CIImage) -> CIImage {
        let key: String = "chroma|\(settings.color.hex)|\(Int(settings.tolerance * 1000))|\(Int(settings.softness * 1000))|\(Int(settings.spill * 100))"
        var data: Data? = cubes.get()[key]
        let size: Int = 32
        if data == nil {
            let made: Data = ColorPipeline.chromaCube(settings, size: size)
            data = made
            cubes.update { c in c[key] = made }
        }
        guard let cube = data else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size,
            "inputCubeData": cube,
            "inputColorSpace": colorSpace
        ])
    }

    static func chromaCube(_ s: ChromaKeySettings, size: Int) -> Data {
        let keyHue: Double = s.color.hue
        let tolerance: Double = max(0.01, s.tolerance)
        let softness: Double = max(0.001, s.softness)
        var values: [Float] = []
        values.reserveCapacity(size * size * size * 4)
        let n: Double = Double(size - 1)
        for bi in 0..<size {
            let b: Double = Double(bi) / n
            for gi in 0..<size {
                let g: Double = Double(gi) / n
                for ri in 0..<size {
                    let r: Double = Double(ri) / n
                    let color = RGBA(r, g, b)
                    let maxC: Double = max(r, max(g, b))
                    let minC: Double = min(r, min(g, b))
                    let sat: Double = maxC <= 0 ? 0 : (maxC - minC) / maxC
                    var distance: Double = abs(color.hue - keyHue)
                    if distance > 0.5 { distance = 1 - distance }
                    var alpha: Double = 1
                    if sat > 0.2 && maxC > 0.15 {
                        let x: Double = Num.clamp((distance - tolerance) / softness, 0, 1)
                        alpha = x * x * (3 - 2 * x)
                    }
                    var rr: Double = r
                    var gg: Double = g
                    var bb: Double = b
                    // 緑・青の色かぶりを抑える
                    if distance < tolerance + softness * 2 {
                        let amount: Double = s.spill * (1 - Num.clamp((distance - tolerance) / (softness * 2), 0, 1))
                        if abs(keyHue - 1.0 / 3.0) < 0.1 {
                            gg = gg - (gg - max(rr, bb)) * amount * (gg > max(rr, bb) ? 1 : 0)
                        } else if abs(keyHue - 2.0 / 3.0) < 0.1 {
                            bb = bb - (bb - max(rr, gg)) * amount * (bb > max(rr, gg) ? 1 : 0)
                        }
                    }
                    values.append(Float(rr * alpha))
                    values.append(Float(gg * alpha))
                    values.append(Float(bb * alpha))
                    values.append(Float(alpha))
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: マスク

    /// クリップの映像の範囲 extent に対するマスク画像（白が残る部分）。
    func maskImage(_ m: MaskSettings, extent: CGRect, at t: Time) -> CIImage {
        let w: CGFloat = extent.width
        let h: CGFloat = extent.height
        let cx: CGFloat = extent.minX + CGFloat(m.centerX.value(at: t)) * w
        let cy: CGFloat = extent.minY + CGFloat(1 - m.centerY.value(at: t)) * h
        let mw: CGFloat = max(1, CGFloat(m.width.value(at: t)) * w)
        let mh: CGFloat = max(1, CGFloat(m.height.value(at: t)) * h)
        let angle: CGFloat = -CGFloat(m.rotation.value(at: t)) * CGFloat.pi / 180
        let feather: CGFloat = max(0, CGFloat(m.feather.value(at: t)) * min(w, h))
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
        var mask: CIImage
        switch m.shape {
        case .rectangle, .mirror:
            let height: CGFloat = m.shape == .mirror ? mh : mh
            let width: CGFloat = m.shape == .mirror ? max(w, h) * 4 : mw
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let transform = CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: cx, y: cy))
            mask = white.cropped(to: rect).transformed(by: transform).composited(over: black)
            if feather > 0.5 {
                mask = mask.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2).cropped(to: extent)
            }
        case .ellipse:
            let radius: CGFloat = 1000
            let inner: CGFloat = max(0, radius - feather * 2 * radius / max(1, min(mw, mh)))
            let gradient: CIImage = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: 0, y: 0),
                "inputRadius0": inner,
                "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0)
            ])?.outputImage ?? white
            let transform = CGAffineTransform(scaleX: mw / (2 * radius), y: mh / (2 * radius))
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
            mask = gradient.transformed(by: transform).cropped(to: extent)
        case .linear:
            let dx: CGFloat = -sin(angle)
            let dy: CGFloat = cos(angle)
            let half: CGFloat = max(1, feather)
            let gradient: CIImage = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: cx - dx * half, y: cy - dy * half),
                "inputPoint1": CIVector(x: cx + dx * half, y: cy + dy * half),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 0, green: 0, blue: 0)
            ])?.outputImage ?? white
            mask = gradient.cropped(to: extent)
        }
        if m.invert {
            mask = mask.applyingFilter("CIColorInvert", parameters: [:])
        }
        return mask
    }

    func applyMask(_ m: MaskSettings, to image: CIImage, at t: Time) -> CIImage {
        let mask: CIImage = maskImage(m, extent: image.extent, at: t)
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }

    func clear() {
        cubes.set([:])
    }
}
#endif
