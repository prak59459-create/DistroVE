#if canImport(AVFoundation)
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO

/// 静止画・GIF のフレームを CIImage として持っておく（大きな写真は縮小して読む）。
final class StillImageCache: @unchecked Sendable {
    private struct GIFFrames {
        var images: [CIImage]
        var starts: [Double]
        var total: Double
    }

    private let stills = Locked<[String: CIImage]>([:])
    private let gifs = Locked<[String: GIFFrames]>([:])

    func image(url: URL, maxPixel: Int) -> CIImage? {
        let key: String = url.path + "#\(maxPixel)"
        if let hit = stills.get()[key] { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = CIImage(cgImage: cg)
        stills.update { cache in
            if cache.count > 40 { cache.removeAll() }
            cache[key] = image
        }
        return image
    }

    /// GIF のローカル時刻（秒）のフレーム。くり返し再生する。
    func gifFrame(url: URL, at seconds: Double, maxPixel: Int) -> CIImage? {
        let key: String = url.path + "#\(maxPixel)"
        var frames: GIFFrames? = gifs.get()[key]
        if frames == nil {
            frames = loadGIF(url: url, maxPixel: maxPixel)
            if let loaded = frames {
                gifs.update { cache in
                    if cache.count > 8 { cache.removeAll() }
                    cache[key] = loaded
                }
            }
        }
        guard let gif = frames, !gif.images.isEmpty else { return image(url: url, maxPixel: maxPixel) }
        if gif.total <= 0 { return gif.images[0] }
        let t: Double = seconds.truncatingRemainder(dividingBy: gif.total)
        var index: Int = 0
        for (i, start) in gif.starts.enumerated() where start <= t {
            index = i
        }
        return gif.images[index]
    }

    private func loadGIF(url: URL, maxPixel: Int) -> GIFFrames? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count: Int = min(CGImageSourceGetCount(source), 300)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, 720)
        ]
        var images: [CIImage] = []
        var starts: [Double] = []
        var cursor: Double = 0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) else { continue }
            images.append(CIImage(cgImage: cg))
            starts.append(cursor)
            cursor += MediaStore.gifDelay(source, index: i)
        }
        return GIFFrames(images: images, starts: starts, total: cursor)
    }

    func clear() {
        stills.set([:])
        gifs.set([:])
    }
}

/// テキストを画像にする（Core Text）。縁取り・影・背景の帯・タイプライター表示に対応する。
final class TextRasterizer: @unchecked Sendable {
    private let cache = Locked<[String: CIImage]>([:])

    /// fontPixels は 1 行の文字の大きさ（ピクセル）、maxWidth は折り返し幅（ピクセル）。
    func image(_ text: TextContent, fontPixels: CGFloat, maxWidth: CGFloat, visibleCharacters: Int? = nil) -> CIImage? {
        let visible: Int = visibleCharacters ?? Int.max
        let key: String = "\(text.hashValue)|\(Int(fontPixels * 4))|\(Int(maxWidth))|\(visible)"
        if let hit = cache.get()[key] { return hit }
        guard let cg = render(text, fontPixels: fontPixels, maxWidth: maxWidth, visible: visible) else { return nil }
        let image = CIImage(cgImage: cg)
        cache.update { c in
            if c.count > 300 { c.removeAll() }
            c[key] = image
        }
        return image
    }

    func clear() {
        cache.set([:])
    }

    static func font(name: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        var base: CTFont
        if name.isEmpty {
            base = CTFontCreateUIFontForLanguage(.system, size, "ja" as CFString) ?? CTFontCreateWithName("HiraginoSans-W6" as CFString, size, nil)
        } else {
            base = CTFontCreateWithName(name as CFString, size, nil)
        }
        var traits = CTFontSymbolicTraits()
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) {
            base = styled
        }
        return base
    }

    private func attributes(_ text: TextContent, font: CTFont, fontPixels: CGFloat, stroke: Bool) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [:]
        attrs[NSAttributedString.Key(kCTFontAttributeName as String)] = font
        attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = NSNumber(value: Double(fontPixels) * text.kerning)
        if stroke {
            attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = text.strokeColor.cgColor
            attrs[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = text.strokeColor.cgColor
            // 正の値は線だけを描く（文字の大きさに対する %）
            attrs[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = NSNumber(value: text.strokeWidth * 100 * 2)
        } else {
            attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = text.color.cgColor
        }
        return attrs
    }

    private struct LineLayout {
        var range: CFRange
        var width: CGFloat
    }

    private func render(_ text: TextContent, fontPixels: CGFloat, maxWidth: CGFloat, visible: Int) -> CGImage? {
        let string: String = text.string.isEmpty ? " " : text.string
        let font: CTFont = TextRasterizer.font(name: text.fontName, size: fontPixels, bold: text.bold, italic: text.italic)
        let fillString = NSAttributedString(string: string, attributes: attributes(text, font: font, fontPixels: fontPixels, stroke: false))
        let strokeString = NSAttributedString(string: string, attributes: attributes(text, font: font, fontPixels: fontPixels, stroke: true))
        let typesetter: CTTypesetter = CTTypesetterCreateWithAttributedString(fillString)
        let ascent: CGFloat = CTFontGetAscent(font)
        let descent: CGFloat = CTFontGetDescent(font)
        let lineHeight: CGFloat = (ascent + descent) * CGFloat(1 + text.lineSpacing)
        let length: Int = (string as NSString).length
        var lines: [LineLayout] = []
        var start: Int = 0
        let wrapWidth: Double = Double(max(fontPixels, maxWidth))
        while start < length {
            var count: Int = CTTypesetterSuggestLineBreak(typesetter, start, wrapWidth)
            if count <= 0 { count = 1 }
            let range = CFRange(location: start, length: count)
            let line: CTLine = CTTypesetterCreateLine(typesetter, range)
            var a: CGFloat = 0
            var d: CGFloat = 0
            var l: CGFloat = 0
            let width: CGFloat = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
            let trailing: CGFloat = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            lines.append(LineLayout(range: range, width: max(0, width - trailing)))
            start += count
        }
        if lines.isEmpty { return nil }
        var textWidth: CGFloat = 1
        for line in lines where line.width > textWidth {
            textWidth = line.width
        }
        let textHeight: CGFloat = lineHeight * CGFloat(lines.count - 1) + ascent + descent
        let strokePad: CGFloat = fontPixels * CGFloat(text.strokeWidth) * 1.2
        let shadowPad: CGFloat = text.shadowBlur > 0 ? fontPixels * CGFloat(text.shadowBlur + text.shadowOffset) * 1.5 : 0
        let bandPad: CGFloat = text.backgroundColor.a > 0.001 ? fontPixels * CGFloat(text.backgroundPadding) : 0
        let pad: CGFloat = ceil(max(2, strokePad + shadowPad + bandPad + 2))
        let width: Int = Int(ceil(textWidth + pad * 2))
        let height: Int = Int(ceil(textHeight + pad * 2))
        if width <= 0 || height <= 0 || width > 8192 || height > 8192 { return nil }
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(true)
        if bandPad > 0 {
            let band = CGRect(x: pad - bandPad, y: pad - bandPad, width: textWidth + bandPad * 2, height: textHeight + bandPad * 2)
            let radius: CGFloat = min(band.height / 2, fontPixels * CGFloat(text.cornerRadius))
            ctx.addPath(CGPath(roundedRect: band, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(text.backgroundColor.cgColor)
            ctx.fillPath()
        }
        let strokeTypesetter: CTTypesetter = CTTypesetterCreateWithAttributedString(strokeString)
        var drawn: Int = 0
        for (index, layout) in lines.enumerated() {
            if drawn >= visible { break }
            let take: Int = min(layout.range.length, visible - drawn)
            drawn += layout.range.length
            let range = CFRange(location: layout.range.location, length: take)
            let baselineY: CGFloat = pad + textHeight - ascent - lineHeight * CGFloat(index)
            var x: CGFloat = pad
            switch text.align {
            case .left: x = pad
            case .center: x = pad + (textWidth - layout.width) / 2
            case .right: x = pad + textWidth - layout.width
            }
            if text.strokeWidth > 0.001 {
                let strokeLine: CTLine = CTTypesetterCreateLine(strokeTypesetter, range)
                ctx.saveGState()
                ctx.setLineJoin(.round)
                if text.shadowBlur > 0.001 {
                    ctx.setShadow(offset: CGSize(width: fontPixels * CGFloat(text.shadowOffset), height: -fontPixels * CGFloat(text.shadowOffset)),
                                  blur: fontPixels * CGFloat(text.shadowBlur), color: text.shadowColor.cgColor)
                }
                ctx.textPosition = CGPoint(x: x, y: baselineY)
                CTLineDraw(strokeLine, ctx)
                ctx.restoreGState()
            }
            let fillLine: CTLine = CTTypesetterCreateLine(typesetter, range)
            ctx.saveGState()
            if text.shadowBlur > 0.001 && text.strokeWidth <= 0.001 {
                ctx.setShadow(offset: CGSize(width: fontPixels * CGFloat(text.shadowOffset), height: -fontPixels * CGFloat(text.shadowOffset)),
                              blur: fontPixels * CGFloat(text.shadowBlur), color: text.shadowColor.cgColor)
            }
            ctx.textPosition = CGPoint(x: x, y: baselineY)
            CTLineDraw(fillLine, ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

/// 図形（矢印・四角・円など）を画像にする。
final class ShapeRasterizer: @unchecked Sendable {
    private let cache = Locked<[String: CIImage]>([:])

    func image(_ shape: ShapeContent, boxHeight: CGFloat) -> CIImage? {
        let key: String = "\(shape.hashValue)|\(Int(boxHeight))"
        if let hit = cache.get()[key] { return hit }
        let h: CGFloat = max(4, boxHeight)
        let w: CGFloat = max(4, h * CGFloat(shape.aspect))
        let lineWidth: CGFloat = max(1, min(w, h) * CGFloat(shape.strokeWidth))
        let pad: CGFloat = lineWidth + 2
        let width: Int = Int(ceil(w + pad * 2))
        let height: Int = Int(ceil(h + pad * 2))
        if width > 8192 || height > 8192 { return nil }
        let space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let box = CGRect(x: pad, y: pad, width: w, height: h)
        let path: CGPath = ShapeRasterizer.path(shape.kind, in: box, lineWidth: lineWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if shape.fill.a > 0.001 {
            ctx.addPath(path)
            ctx.setFillColor(shape.fill.cgColor)
            ctx.fillPath()
        }
        if shape.stroke.a > 0.001 && shape.kind != .arrow {
            ctx.addPath(path)
            ctx.setStrokeColor(shape.stroke.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        cache.update { c in
            if c.count > 100 { c.removeAll() }
            c[key] = image
        }
        return image
    }

    static func path(_ kind: ShapeKind, in r: CGRect, lineWidth: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch kind {
        case .rectangle:
            path.addRect(r)
        case .roundedRectangle:
            let radius: CGFloat = min(r.width, r.height) * 0.2
            path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        case .ellipse:
            path.addEllipse(in: r)
        case .triangle:
            path.move(to: CGPoint(x: r.midX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            path.addLine(to: CGPoint(x: r.minX, y: r.minY))
            path.closeSubpath()
        case .star:
            let center = CGPoint(x: r.midX, y: r.midY)
            let outer: CGFloat = min(r.width, r.height) / 2
            let inner: CGFloat = outer * 0.45
            for i in 0..<10 {
                let angle: CGFloat = CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / 5
                let radius: CGFloat = i % 2 == 0 ? outer : inner
                let p = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        case .arrow:
            let shaft: CGFloat = r.height * 0.32
            let headLength: CGFloat = min(r.width * 0.45, r.height * 1.1)
            path.move(to: CGPoint(x: r.minX, y: r.midY - shaft / 2))
            path.addLine(to: CGPoint(x: r.maxX - headLength, y: r.midY - shaft / 2))
            path.addLine(to: CGPoint(x: r.maxX - headLength, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            path.addLine(to: CGPoint(x: r.maxX - headLength, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX - headLength, y: r.midY + shaft / 2))
            path.addLine(to: CGPoint(x: r.minX, y: r.midY + shaft / 2))
            path.closeSubpath()
        case .line:
            path.move(to: CGPoint(x: r.minX, y: r.midY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        }
        return path
    }
}
#endif
