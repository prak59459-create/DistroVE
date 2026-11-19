#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import Foundation
import Vision

/// 背景除去（Q45）。Vision の人物セグメンテーションを端末内で使う。動画は端末の外に出さない。
final class PersonSegmenter: @unchecked Sendable {
    private let lock = NSLock()
    private let request: VNGeneratePersonSegmentationRequest

    init() {
        request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func cutout(_ image: CIImage) -> CIImage {
        lock.lock()
        defer { lock.unlock() }
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return image
        }
        guard let result = request.results?.first else { return image }
        let maskBuffer: CVPixelBuffer = result.pixelBuffer
        var mask = CIImage(cvPixelBuffer: maskBuffer)
        let sx: CGFloat = image.extent.width / max(1, mask.extent.width)
        let sy: CGFloat = image.extent.height / max(1, mask.extent.height)
        mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
        return image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }
}

/// 映像の解析（手ぶれ補正・被写体の位置・動きの量）。
enum VisionTools {
    /// 区間を一定間隔で小さく取り出したフレーム。
    static func sampledFrames(url: URL, start: Time, duration: Time, interval: Time, maxSide: CGFloat,
                              progress: ((Double) -> Void)? = nil) async throws -> [CGImage] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance: CMTime = Time(ticks: interval.ticks / 3).cmTime
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var frames: [CGImage] = []
        let count: Int = max(1, Int(duration.ticks / max(1, interval.ticks)))
        for i in 0...count {
            if Task.isCancelled { throw EngineError.cancelled }
            let t: Time = start + Time(ticks: interval.ticks * Int64(i))
            if t > start + duration { break }
            if let result = try? await generator.image(at: t.cmTime) {
                frames.append(result.image)
            }
            progress?(Double(i) / Double(count))
        }
        return frames
    }

    /// 手ぶれ補正（Q42）。隣り合うフレームのずれを Vision で求め、なめらかにした軌跡との差を補正量にする。
    static func stabilization(url: URL, sourceStart: Time, sourceDuration: Time, strength: Double = 1,
                              progress: ((Double) -> Void)? = nil) async throws -> StabilizationData {
        let interval = Time(seconds: 1.0 / 15.0)
        let frames: [CGImage] = try await sampledFrames(url: url, start: sourceStart, duration: sourceDuration, interval: interval,
                                                        maxSide: 320, progress: { p in progress?(p * 0.6) })
        if frames.count < 3 { throw EngineError.unreadable("フレームが足りません") }
        var pathX: [Double] = [0]
        var pathY: [Double] = [0]
        for i in 1..<frames.count {
            if Task.isCancelled { throw EngineError.cancelled }
            let request = VNTranslationalImageRegistrationRequest(targetedCGImage: frames[i], options: [:])
            let handler = VNImageRequestHandler(cgImage: frames[i - 1], options: [:])
            var dx: Double = 0
            var dy: Double = 0
            if (try? handler.perform([request])) != nil, let observation = request.results?.first {
                let transform: CGAffineTransform = observation.alignmentTransform
                dx = Double(transform.tx) / Double(frames[i].width)
                dy = Double(transform.ty) / Double(frames[i].height)
            }
            pathX.append(pathX[pathX.count - 1] + dx)
            pathY.append(pathY[pathY.count - 1] + dy)
            progress?(0.6 + 0.4 * Double(i) / Double(frames.count))
        }
        let smoothX: [Double] = movingAverage(pathX, radius: 12)
        let smoothY: [Double] = movingAverage(pathY, radius: 12)
        var offsets: [Vec2] = []
        var maxShift: Double = 0
        // alignmentTransform は「後のフレームを前のフレームに重ねる」移動量。積み上げた軌跡からなめらかな成分を引いた残りが揺れ
        for i in 0..<pathX.count {
            let ox: Double = pathX[i] - smoothX[i]
            let oy: Double = pathY[i] - smoothY[i]
            offsets.append(Vec2(ox, oy))
            maxShift = max(maxShift, max(abs(ox), abs(oy)))
        }
        // 補正の分だけ画面端が見えないよう拡大する
        let zoom: Double = Num.clamp(1 + maxShift * 2 * strength + 0.02, 1.03, 1.3)
        return StabilizationData(interval: interval, offsets: offsets, strength: strength, zoom: zoom)
    }

    static func movingAverage(_ values: [Double], radius: Int) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(values.count)
        for i in 0..<values.count {
            let lo: Int = max(0, i - radius)
            let hi: Int = min(values.count - 1, i + radius)
            var sum: Double = 0
            for j in lo...hi { sum += values[j] }
            result.append(sum / Double(hi - lo + 1))
        }
        return result
    }

    /// 被写体（顔、なければ目立つもの）の横位置 0〜1。縦型ショートへの変換で使う。
    static func subjectCenterX(url: URL, at time: Time) async -> Double? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let frame = try? await generator.image(at: time.cmTime).image else { return nil }
        let handler = VNImageRequestHandler(cgImage: frame, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([faces])) != nil, let results = faces.results, !results.isEmpty {
            var sum: Double = 0
            var weight: Double = 0
            for face in results {
                let area: Double = Double(face.boundingBox.width * face.boundingBox.height)
                sum += Double(face.boundingBox.midX) * area
                weight += area
            }
            if weight > 0 { return sum / weight }
        }
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        if (try? handler.perform([saliency])) != nil, let observation = saliency.results?.first,
           let objects = observation.salientObjects, let first = objects.first {
            return Double(first.boundingBox.midX)
        }
        return nil
    }

    /// 1 秒ごとの映像の変化量（0〜1）。ハイライト抽出の手がかりにする。
    static func motionScores(url: URL, duration: Time, progress: ((Double) -> Void)? = nil) async throws -> [Double] {
        let step = Time(seconds: 1)
        let frames: [CGImage] = try await sampledFrames(url: url, start: .zero, duration: duration, interval: step, maxSide: 64, progress: progress)
        var previous: [UInt8]?
        var scores: [Double] = []
        for frame in frames {
            let pixels: [UInt8] = grayscale(frame, width: 32, height: 18)
            if let prev = previous {
                var diff: Int = 0
                for i in 0..<min(prev.count, pixels.count) {
                    diff += abs(Int(prev[i]) - Int(pixels[i]))
                }
                scores.append(min(1, Double(diff) / Double(max(1, pixels.count)) / 64))
            } else {
                scores.append(0)
            }
            previous = pixels
        }
        return scores
    }

    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8] {
        var pixels: [UInt8] = Array(repeating: 0, count: width * height)
        let space: CGColorSpace = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buffer in
            if let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .low
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        return pixels
    }
}
#endif
