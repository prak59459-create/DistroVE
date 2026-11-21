import XCTest
@testable import DistroKit

/// 速さ・速度カーブ・フレームレートからコマの時刻を決める計画（Q34, Q99）。
final class RetimePlanTests: XCTestCase {
    private func videoAsset(seconds: Double = 20, fps: Double = 30) -> MediaAsset {
        var asset = MediaAsset(kind: .video, name: "v", storage: .copied)
        asset.duration = Time(seconds: seconds)
        asset.frameRate = fps
        asset.width = 1920
        asset.height = 1080
        return asset
    }

    private func clip(start: Double = 0, duration: Double = 2, sourceStart: Double = 1, rate: Double = 1) -> Clip {
        var c = Clip(kind: .video, name: "v", start: Time(seconds: start), duration: Time(seconds: duration))
        c.sourceStart = Time(seconds: sourceStart)
        c.speed = SpeedSettings(rate: rate)
        c.speed.interpolation = .opticalFlow
        return c
    }

    func testHalfSpeedMakesOneFramePerTimelineFrame() {
        let plan = RetimePlan(clip: clip(rate: 0.5), asset: videoAsset(), fps: 30)
        XCTAssertEqual(plan.frames.count, 60)
        XCTAssertEqual(plan.frames[0].sourceTime, 1, accuracy: 1e-6)
        XCTAssertEqual(plan.frames[1].sourceTime, 1 + 0.5 / 30, accuracy: 1e-4)
        XCTAssertEqual(plan.frames[59].outputTime, 59.0 / 30, accuracy: 1e-6)
        XCTAssertEqual(plan.frames[59].sourceTime, 1 + 59.0 * 0.5 / 30, accuracy: 1e-4)
        XCTAssertFalse(plan.frames[0].hasExposure)
        // 半分の速さでは素材のコマの間が要る
        XCTAssertTrue(plan.isNeeded(sourceFPS: 30))
        // 60fps の素材なら素材のコマをそのまま使えば足りる
        XCTAssertFalse(plan.isNeeded(sourceFPS: 60))
        XCTAssertEqual(plan.sourceStart, 1, accuracy: 1e-6)
        XCTAssertEqual(plan.sourceEnd, 2, accuracy: 1e-6)
    }

    func testFrameRateConversionAtNormalSpeed() {
        // 24fps の素材を 60fps のプロジェクトに置く
        let plan = RetimePlan(clip: clip(rate: 1), asset: videoAsset(fps: 24), fps: 60)
        XCTAssertEqual(plan.frames.count, 120)
        XCTAssertTrue(plan.isNeeded(sourceFPS: 24))
        // 30fps の素材を 30fps に置くだけなら要らない
        let same = RetimePlan(clip: clip(rate: 1), asset: videoAsset(fps: 30), fps: 30)
        XCTAssertFalse(same.isNeeded(sourceFPS: 30))
        // 2 倍速でも素材のコマにぴったり重なるので要らない
        let double = RetimePlan(clip: clip(rate: 2), asset: videoAsset(fps: 30), fps: 30)
        XCTAssertFalse(double.isNeeded(sourceFPS: 30))
        // 1.5 倍速はコマの間を写すので要る（カクつきをなくせる）
        let oneHalf = RetimePlan(clip: clip(rate: 1.5), asset: videoAsset(fps: 30), fps: 30)
        XCTAssertTrue(oneHalf.isNeeded(sourceFPS: 30))
        // コマの繰り返しなら作らない
        var sampled = clip(rate: 0.5)
        sampled.speed.interpolation = .sampling
        XCTAssertFalse(RetimePlan(clip: sampled, asset: videoAsset(), fps: 30).isNeeded(sourceFPS: 30))
    }

    func testFramesFollowTheTimelineGridWhenTheClipStartsBetweenFrames() {
        // 1/60 秒ずれた位置から始まるクリップ（30fps のコマは 1/30 秒ごと）
        let asset = videoAsset()
        let plan = RetimePlan(clip: clip(start: 1.0 / 60, duration: 1, rate: 1), asset: asset, fps: 30)
        XCTAssertEqual(plan.frames[0].outputTime, 1.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(plan.frames.count, 30)
        // 位置が違えば別のキャッシュ、コマ単位で動かしただけなら同じキャッシュ
        let moved = RetimePlan(clip: clip(start: 1 + 1.0 / 60, duration: 1, rate: 1), asset: asset, fps: 30)
        XCTAssertEqual(plan.cachePath, moved.cachePath, plan.signature + " / " + moved.signature)
        let aligned = RetimePlan(clip: clip(start: 1, duration: 1, rate: 1), asset: asset, fps: 30)
        XCTAssertNotEqual(plan.cachePath, aligned.cachePath)
    }

    func testSpeedCurveSlowsDownInTheMiddle() {
        var c = clip(duration: 3, sourceStart: 0, rate: 1)
        c.speed.curve = [SpeedPoint(0, 2), SpeedPoint(0.5, 0.25), SpeedPoint(1, 2)]
        let plan = RetimePlan(clip: c, asset: videoAsset(), fps: 30)
        XCTAssertEqual(plan.frames.count, 90)
        let start: Double = plan.frames[1].sourceTime - plan.frames[0].sourceTime
        let middle: Double = plan.frames[46].sourceTime - plan.frames[45].sourceTime
        XCTAssertEqual(start * 30, 2, accuracy: 0.1)
        XCTAssertEqual(middle * 30, 0.25, accuracy: 0.05)
        // 素材の時刻は必ず進む
        for i in 1..<plan.frames.count {
            XCTAssertGreaterThan(plan.frames[i].sourceTime, plan.frames[i - 1].sourceTime)
        }
        XCTAssertEqual(plan.sourceEnd, SpeedMap(settings: c.speed).sourceDuration(forTimeline: c.duration).seconds, accuracy: 0.01)
    }

    func testMotionBlurExposureFollowsTheSpeed() {
        var c = clip(rate: 4)
        c.speed.interpolation = .sampling
        c.speed.motionBlur = 0.5
        let plan = RetimePlan(clip: c, asset: videoAsset(), fps: 30)
        // ブラーだけを付けるときも作る（ブラーの中のコマは光学フロー）
        XCTAssertEqual(plan.interpolation, .opticalFlow)
        XCTAssertTrue(plan.isNeeded(sourceFPS: 30))
        let frame: RetimeFrame = plan.frames[10]
        XCTAssertTrue(frame.hasExposure)
        // 4 倍速・180° なら、1 コマのあいだに素材が 4/30 秒進み、その半分が写る
        XCTAssertEqual(frame.exposureEnd - frame.exposureStart, 0.5 * 4 / 30, accuracy: 1e-4)
        XCTAssertEqual((frame.exposureEnd + frame.exposureStart) / 2, frame.sourceTime, accuracy: 1e-4)
        // 最初のコマは、クリップの前の素材も少し使う
        XCTAssertLessThan(plan.sourceStart, 1)
    }

    func testReversedClipUsesTheReversedFileTimes() {
        var c = clip(duration: 2, sourceStart: 5, rate: 1)
        c.speed.reversed = true
        let plan = RetimePlan(clip: c, asset: videoAsset(seconds: 20), fps: 30)
        // 逆順のファイルでは 20 - 5 - 2 = 13 秒から
        XCTAssertEqual(plan.frames[0].sourceTime, 13, accuracy: 1e-6)
        XCTAssertNotEqual(plan.signature, RetimePlan(clip: clip(duration: 2, sourceStart: 5), asset: videoAsset(seconds: 20), fps: 30).signature)
        XCTAssertTrue(plan.signature.contains("|rev|"))
    }

    func testSignatureChangesWithEverySettingThatChangesTheResult() {
        let asset = videoAsset()
        let base = RetimePlan(clip: clip(rate: 0.5), asset: asset, fps: 30)
        XCTAssertEqual(base.cachePath, RetimePlan(clip: clip(rate: 0.5), asset: asset, fps: 30).cachePath)
        XCTAssertTrue(base.cachePath.hasPrefix("Retimed/"))
        XCTAssertTrue(base.cachePath.hasSuffix(".mov"))
        var blended = clip(rate: 0.5)
        blended.speed.interpolation = .blending
        var blurred = clip(rate: 0.5)
        blurred.speed.motionBlur = 0.25
        let others: [RetimePlan] = [
            RetimePlan(clip: clip(rate: 0.25), asset: asset, fps: 30),
            RetimePlan(clip: clip(rate: 0.5), asset: asset, fps: 60),
            RetimePlan(clip: clip(duration: 3, rate: 0.5), asset: asset, fps: 30),
            RetimePlan(clip: clip(sourceStart: 2, rate: 0.5), asset: asset, fps: 30),
            RetimePlan(clip: blended, asset: asset, fps: 30),
            RetimePlan(clip: blurred, asset: asset, fps: 30),
            RetimePlan(clip: clip(rate: 0.5), asset: { () -> MediaAsset in
                var longer = asset
                longer.duration = Time(seconds: 21)
                return longer
            }(), fps: 30)
        ]
        for other in others {
            XCTAssertNotEqual(other.cachePath, base.cachePath, other.signature)
        }
        XCTAssertEqual(RetimePlan.hexHash("").count, 16)
        XCTAssertEqual(RetimePlan.hexHash("a"), "af63dc4c8601ec8c")
    }
}

/// 素材のコマのどこを使うか（コマの間・シャッターの区間）。
final class FrameTimingTests: XCTestCase {
    private let times: [Double] = [0, 0.1, 0.2, 0.3]

    func testPairInsideAndOutside() {
        let middle: FramePair = FrameTiming.pair(for: 0.15, in: times)
        XCTAssertEqual(middle.first, 1)
        XCTAssertEqual(middle.second, 2)
        XCTAssertEqual(middle.position, 0.5, accuracy: 1e-9)
        XCTAssertEqual(FrameTiming.pair(for: 0, in: times), FramePair(first: 0, second: 1, position: 0))
        XCTAssertEqual(FrameTiming.pair(for: 0.1, in: times).first, 1)
        XCTAssertEqual(FrameTiming.pair(for: 0.1, in: times).position, 0, accuracy: 1e-9)
        XCTAssertEqual(FrameTiming.pair(for: -1, in: times), FramePair(first: 0, second: 0, position: 0))
        XCTAssertEqual(FrameTiming.pair(for: 5, in: times), FramePair(first: 3, second: 3, position: 0))
        XCTAssertEqual(FrameTiming.pair(for: 1, in: [0.5]), FramePair(first: 0, second: 0, position: 0))
    }

    func testExposureSplitsAcrossFramesAndWeightsSumToOne() {
        let parts: [ExposureSegment] = FrameTiming.segments(from: 0.05, to: 0.25, in: times)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts[0].first, 0)
        XCTAssertEqual(parts[0].from, 0.5, accuracy: 1e-9)
        XCTAssertEqual(parts[0].to, 1, accuracy: 1e-9)
        XCTAssertEqual(parts[1].first, 1)
        XCTAssertEqual(parts[2].to, 0.5, accuracy: 1e-9)
        var total: Double = 0
        for p in parts { total += p.weight }
        XCTAssertEqual(total, 1, accuracy: 1e-9)
        XCTAssertEqual(parts[0].weight, 0.25, accuracy: 1e-9)
        // 素材の外にはみ出たぶんは端のコマで埋める
        let edge: [ExposureSegment] = FrameTiming.segments(from: -0.1, to: 0.05, in: times)
        XCTAssertEqual(edge.first?.first, 0)
        XCTAssertEqual(edge.first?.second, 0)
        XCTAssertEqual(edge.first?.weight ?? 0, 0.1 / 0.15, accuracy: 1e-9)
        XCTAssertEqual(edge.count, 2)
        var edgeTotal: Double = 0
        for p in edge { edgeTotal += p.weight }
        XCTAssertEqual(edgeTotal, 1, accuracy: 1e-9)
        // シャッターが閉じているときは 1 か所
        XCTAssertEqual(FrameTiming.segments(from: 0.12, to: 0.12, in: times).count, 1)
    }
}

/// カットの判定（カットの前後ではコマの間を作らない）。
final class SceneCutTests: XCTestCase {
    private func scene(_ kind: Int, shift: Double = 0, gain: Double = 1) -> CutSignature {
        var image = GrayImage(width: 160, height: 90, pixels: [])
        var pixels: [Float] = []
        pixels.reserveCapacity(160 * 90)
        for y in 0..<90 {
            for x in 0..<160 {
                let u: Double = Double(x) - shift
                let v: Double = Double(y)
                let value: Double
                switch kind {
                case 0: value = 128 + 70 * sin(u / 9) * cos(v / 7) + 30 * sin((u + v) / 23)
                case 1: value = 120 + 80 * cos(u / 31 + 1.3) * sin(v / 5 + 0.4) - 25 * cos((u - 2 * v) / 13)
                default: value = 60 + 1.2 * v + 40 * sin(u / 17) * sin(u / 4 + v / 6)
                }
                pixels.append(Float(max(0, min(255, value * gain))))
            }
        }
        image.pixels = pixels
        return CutSignature(thumbnail: CutSignature.thumbnail(of: image))
    }

    private func flat(_ value: Float) -> CutSignature {
        return CutSignature(thumbnail: Array(repeating: value, count: CutSignature.columns * CutSignature.rows))
    }

    func testContinuousMotionIsNotACut() {
        var detector = SceneCutDetector()
        for i in 0..<12 {
            XCTAssertFalse(detector.isCut(scene(0, shift: Double(i) * 3), scene(0, shift: Double(i + 1) * 3)), "コマ \(i)")
        }
        // 速い動きがずっと続いてもカットにしない
        var fast = SceneCutDetector()
        for i in 0..<8 {
            XCTAssertFalse(fast.isCut(scene(2, shift: Double(i) * 10), scene(2, shift: Double(i + 1) * 10)), "速いコマ \(i)")
        }
    }

    func testHardCutIsFoundOnlyAtTheCut() {
        var detector = SceneCutDetector()
        var found: [Int] = []
        let frames: [CutSignature] = [scene(0), scene(0, shift: 2), scene(0, shift: 4), scene(1), scene(1, shift: 2), scene(2), scene(2, shift: 1)]
        for i in 1..<frames.count where detector.isCut(frames[i - 1], frames[i]) {
            found.append(i)
        }
        XCTAssertEqual(found, [3, 5])
        // 最初の 2 コマがいきなりカットでも見つける
        var first = SceneCutDetector()
        XCTAssertTrue(first.isCut(scene(0), scene(1)))
    }

    /// 暗い背景を小さな明るい四角が速く動き、そのあと別の場面に切り替わる（macOS のコマ作りのテストと同じ形）。
    func testSmallFastObjectThenCut() {
        func square(_ left: Int) -> CutSignature {
            var pixels: [Float] = Array(repeating: 30, count: 320 * 240)
            for y in 96..<144 {
                for x in left..<min(320, left + 48) {
                    pixels[y * 320 + x] = ((x - left) / 8 + (y - 96) / 8) % 2 == 0 ? 255 : 200
                }
            }
            return CutSignature(thumbnail: CutSignature.thumbnail(of: GrayImage(width: 320, height: 240, pixels: pixels)))
        }
        func stripes(_ offset: Int) -> CutSignature {
            var pixels: [Float] = []
            pixels.reserveCapacity(320 * 240)
            for y in 0..<240 {
                for x in 0..<320 {
                    pixels.append(((y + offset * 2) / 20) % 2 == 0 ? Float(90 + x % 40) : 160)
                }
            }
            return CutSignature(thumbnail: CutSignature.thumbnail(of: GrayImage(width: 320, height: 240, pixels: pixels)))
        }
        var detector = SceneCutDetector()
        for i in 0..<14 {
            XCTAssertFalse(detector.isCut(square(20 + i * 8), square(28 + i * 8)), "コマ \(i)")
        }
        XCTAssertTrue(detector.isCut(square(20 + 14 * 8), stripes(0)))
        XCTAssertFalse(detector.isCut(stripes(0), stripes(1)))
    }

    func testFadesAndBrightnessChangesAreNotCuts() {
        var detector = SceneCutDetector()
        var gain: Double = 1
        for _ in 0..<10 {
            XCTAssertFalse(detector.isCut(scene(0, gain: gain), scene(0, gain: gain * 0.85)))
            gain *= 0.85
        }
        var dark = SceneCutDetector()
        XCTAssertFalse(dark.isCut(flat(4), flat(3)))
        // 黒から場面へのカットは見つける
        XCTAssertTrue(dark.isCut(flat(2), scene(1)))
    }

    func testStillFramesAreRecognised() {
        XCTAssertTrue(SceneCutDetector.isStill(scene(0), scene(0)))
        // ゆっくり動いていれば止まっているとみなさない
        XCTAssertFalse(SceneCutDetector.isStill(scene(0), scene(0, shift: 1)))
        XCTAssertFalse(SceneCutDetector.isStill(scene(0), scene(0, gain: 1.02)))
    }
}

/// スムースカット（光学フローのトランジション）の計画。
final class SmoothCutPlanTests: XCTestCase {
    private func setup(transition: TransitionKind = .smoothCut) -> (Project, MediaAsset) {
        var asset = MediaAsset(kind: .video, name: "v", storage: .copied)
        asset.duration = Time(seconds: 10)
        asset.frameRate = 30
        asset.width = 1920
        asset.height = 1080
        var project = Project(name: "p", canvas: CanvasSettings(aspect: .landscape16x9, shortSide: 1080, fps: 30))
        project.media.append(asset)
        var a: Clip = project.makeClip(for: asset)
        a.sourceStart = .zero
        a.duration = Time(seconds: 1)
        project.appendToMain(a)
        var b: Clip = project.makeClip(for: asset)
        b.sourceStart = Time(seconds: 3)
        b.duration = Time(seconds: 1)
        b.transitionIn = ClipTransition(kind: transition, duration: Time(seconds: 0.4))
        project.appendToMain(b)
        return (project, asset)
    }

    func testPlanCoversTheWindowAroundTheCut() throws {
        let (project, _) = setup()
        let items = SmoothCutPlan.all(in: project, fps: 30)
        XCTAssertEqual(items.count, 1)
        let plan: SmoothCutPlan = try XCTUnwrap(items.first?.plan)
        XCTAssertEqual(plan.windowStart.seconds, 0.8, accuracy: 1e-6)
        XCTAssertEqual(plan.duration.seconds, 0.4, accuracy: 1e-6)
        XCTAssertEqual(plan.outputTimes.count, 12)
        XCTAssertEqual(plan.outputTimes[1] - plan.outputTimes[0], 1.0 / 30, accuracy: 1e-6)
        // 区間の始まりで A が写す 0.8 秒のコマから、区間の終わりで B が写す 3.2 秒のコマへ
        XCTAssertEqual(plan.fromTime, 0.8, accuracy: 1e-6)
        XCTAssertEqual(plan.toTime, 3.2, accuracy: 1e-6)
        for i in 1..<plan.progress.count {
            XCTAssertGreaterThan(plan.progress[i], plan.progress[i - 1])
        }
        XCTAssertLessThan(plan.progress[0], 0.05)
        XCTAssertGreaterThan(plan.progress[plan.progress.count - 1], 0.95)
        XCTAssertTrue(plan.cachePath.hasPrefix("Retimed/morph-"))
        // フレームレートが違えば別のファイル
        let other: SmoothCutPlan = try XCTUnwrap(SmoothCutPlan.all(in: project, fps: 60).first?.plan)
        XCTAssertNotEqual(other.cachePath, plan.cachePath)
        XCTAssertEqual(other.outputTimes.count, 24)
    }

    func testOnlySmoothCutsBetweenForwardVideoClips() {
        let (fade, _) = setup(transition: .fade)
        XCTAssertTrue(SmoothCutPlan.all(in: fade, fps: 30).isEmpty)
        var (reversed, _) = setup()
        if let main = reversed.mainTrackIndex {
            reversed.tracks[main].clips[1].speed.reversed = true
        }
        XCTAssertTrue(SmoothCutPlan.all(in: reversed, fps: 30).isEmpty)
    }
}
