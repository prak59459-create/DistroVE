#if canImport(Vision) && canImport(AVFoundation)
import AVFoundation
import XCTest
@testable import DistroKit

/// オプティカルフローのコマ補間（Q99）を実際に動かすテスト（macOS で実行）。
final class InterpolationTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("distrove-flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AppPaths.overrideRoot = root
    }

    override func tearDown() {
        AppPaths.overrideRoot = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private let width: Int = 320
    private let height: Int = 240
    private let squareSize: Int = 48

    /// 市松模様の四角が 1 コマに 8 画素ずつ右へ動く動画。
    private func makeMovingSquare(frames: Int, fps: Int) async throws -> URL {
        let url: URL = root.appendingPathComponent("square.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [:]
        settings[AVVideoCodecKey] = AVVideoCodecType.h264
        settings[AVVideoWidthKey] = width
        settings[AVVideoHeightKey] = height
        var quality: [String: Any] = [:]
        quality[AVVideoAverageBitRateKey] = 8_000_000
        settings[AVVideoCompressionPropertiesKey] = quality
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        attributes[kCVPixelBufferWidthKey as String] = width
        attributes[kCVPixelBufferHeightKey as String] = height
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &made)
            let buffer: CVPixelBuffer = try XCTUnwrap(made)
            draw(buffer, left: 20 + i * 8, top: 96)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func draw(_ buffer: CVPixelBuffer, left: Int, top: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base: UnsafeMutablePointer<UInt8> = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let inside: Bool = x >= left && x < left + squareSize && y >= top && y < top + squareSize
                let checker: Bool = ((x - left) / 8 + (y - top) / 8) % 2 == 0
                let value: UInt8 = inside ? (checker ? 255 : 200) : 30
                let p: Int = y * bytesPerRow + x * 4
                base[p] = value
                base[p + 1] = value
                base[p + 2] = value
                base[p + 3] = 255
            }
        }
    }

    /// 明るい画素の重心の x と、その数。
    private func brightCentroid(_ buffer: CVPixelBuffer) -> (x: Double, count: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base: UnsafeMutablePointer<UInt8> = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow: Int = CVPixelBufferGetBytesPerRow(buffer)
        var sum: Double = 0
        var count: Int = 0
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            for x in 0..<CVPixelBufferGetWidth(buffer) where base[y * bytesPerRow + x * 4 + 1] > 150 {
                sum += Double(x)
                count += 1
            }
        }
        return (count > 0 ? sum / Double(count) : -1, count)
    }

    func testInterpolatedFramesPutTheSquareHalfway() async throws {
        let interpolator: FrameInterpolator = try XCTUnwrap(FrameInterpolator.shared)
        let source: URL = try await makeMovingSquare(frames: 30, fps: 30)
        let output: URL = root.appendingPathComponent("smooth.mov")
        let range = TimeRange(start: .zero, duration: Time(seconds: 1))
        try await interpolator.interpolate(url: source, range: range, factor: 2, accuracy: .high, output: output, progress: nil)

        let asset = AVURLAsset(url: output)
        let track: AVAssetTrack = try XCTUnwrap(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        var attributes: [String: Any] = [:]
        attributes[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_32BGRA
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: attributes)
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var centroids: [(x: Double, count: Int)] = []
        var times: [Double] = []
        while let sample = out.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            centroids.append(brightCentroid(buffer))
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        XCTAssertGreaterThanOrEqual(centroids.count, 57)
        XCTAssertLessThanOrEqual(centroids.count, 60)
        XCTAssertEqual(times[1] - times[0], 1.0 / 60, accuracy: 0.002)
        for k in 5..<20 {
            let before = centroids[2 * k]
            let middle = centroids[2 * k + 1]
            let after = centroids[2 * k + 2]
            let expected: Double = (before.x + after.x) / 2
            XCTAssertEqual(middle.x, expected, accuracy: 2.5, "コマ \(2 * k + 1)")
            // 二重にぼやけていない（明るい画素が元のコマと同じくらいある）
            XCTAssertGreaterThan(Double(middle.count), Double(before.count) * 0.7, "コマ \(2 * k + 1)")
        }
    }
}
#endif
