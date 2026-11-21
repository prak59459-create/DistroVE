import XCTest
@testable import DistroKit

final class EditingTests: XCTestCase {
    func makeVideo(_ seconds: Double, name: String = "v") -> MediaAsset {
        var a = MediaAsset(kind: .video, name: name, storage: .copied)
        a.duration = Time(seconds: seconds)
        a.width = 1920
        a.height = 1080
        a.hasAudio = true
        return a
    }

    func makeProject(_ lengths: [Double]) -> Project {
        var p = Project(name: "t", canvas: CanvasSettings(aspect: .landscape16x9))
        for (i, l) in lengths.enumerated() {
            let asset = makeVideo(l, name: "v\(i)")
            p.media.append(asset)
            p.appendToMain(p.makeClip(for: asset))
        }
        return p
    }

    var main: [Clip] { return [] }

    func testAppendAndInsertOnMain() {
        var p = makeProject([4, 6])
        XCTAssertEqual(p.tracks[0].clips.map { $0.start }, [.zero, Time(seconds: 4)])
        let asset = makeVideo(2)
        p.media.append(asset)
        p.insertOnMain(p.makeClip(for: asset), at: Time(seconds: 5))
        // 5 秒は 2 本目（4〜10 秒）の前半なので、2 本目の前に入る
        XCTAssertEqual(p.tracks[0].clips.count, 3)
        XCTAssertEqual(p.tracks[0].clips[1].mediaID, asset.id)
        XCTAssertEqual(p.tracks[0].clips[2].start, Time(seconds: 6))
        XCTAssertEqual(p.duration, Time(seconds: 12))
    }

    func testSplitKeepsSourcePositions() {
        var p = makeProject([10])
        let id = p.tracks[0].clips[0].id
        p.setSpeed(clipID: id, rate: 2)
        XCTAssertEqual(p.tracks[0].clips[0].duration, Time(seconds: 5))
        let right = p.split(clipID: id, at: Time(seconds: 2))
        XCTAssertNotNil(right)
        let clips = p.tracks[0].clips
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].duration, Time(seconds: 2))
        XCTAssertEqual(clips[1].start, Time(seconds: 2))
        XCTAssertEqual(clips[1].sourceStart, Time(seconds: 4))
        XCTAssertEqual(clips[1].duration, Time(seconds: 3))
        // 端すぎる位置では分割しない
        XCTAssertNil(p.split(clipID: clips[0].id, at: Time(ticks: 1)))
    }

    func testSplitReversedClip() {
        var p = makeProject([10])
        let id = p.tracks[0].clips[0].id
        p.updateClip(id) { $0.speed.reversed = true }
        let right = p.split(clipID: id, at: Time(seconds: 3))!
        let left = p.clip(id)!
        let r = p.clip(right)!
        // 逆再生の前半は素材の後ろ 3 秒（7〜10 秒）
        XCTAssertEqual(left.sourceStart, Time(seconds: 7))
        XCTAssertEqual(r.sourceStart, .zero)
        XCTAssertEqual(r.sourceDuration, Time(seconds: 7))
    }

    func testRippleDeleteOnMagneticMain() {
        var p = makeProject([2, 3, 4])
        let middle = p.tracks[0].clips[1].id
        p.delete(clipIDs: [middle], ripple: false)
        XCTAssertEqual(p.tracks[0].clips.count, 2)
        XCTAssertEqual(p.tracks[0].clips[1].start, Time(seconds: 2))
        p.magneticMainTrack = false
        let first = p.tracks[0].clips[0].id
        p.delete(clipIDs: [first], ripple: false)
        XCTAssertEqual(p.tracks[0].clips[0].start, Time(seconds: 2))
        p.closeGap(trackID: p.tracks[0].id, at: Time(seconds: 1))
        XCTAssertEqual(p.tracks[0].clips[0].start, .zero)
    }

    func testTrimLimits() {
        var p = makeProject([10, 5])
        let id = p.tracks[0].clips[0].id
        // 素材より長くは伸ばせない
        p.trim(clipID: id, edge: .trailing, to: Time(seconds: 20))
        XCTAssertEqual(p.clip(id)?.duration, Time(seconds: 10))
        p.trim(clipID: id, edge: .trailing, to: Time(seconds: 6))
        XCTAssertEqual(p.clip(id)?.duration, Time(seconds: 6))
        XCTAssertEqual(p.tracks[0].clips[1].start, Time(seconds: 6))
        // 先頭を 2 秒詰めると、素材の 2 秒目から始まる（マグネットなので位置は 0 のまま）
        p.trim(clipID: id, edge: .leading, to: Time(seconds: 2))
        XCTAssertEqual(p.clip(id)?.sourceStart, Time(seconds: 2))
        XCTAssertEqual(p.clip(id)?.start, .zero)
        XCTAssertEqual(p.clip(id)?.duration, Time(seconds: 4))
        // 先頭は素材の 0 秒より前に伸ばせない
        p.trim(clipID: id, edge: .leading, to: Time(seconds: -10))
        XCTAssertEqual(p.clip(id)?.sourceStart, .zero)
        XCTAssertEqual(p.clip(id)?.duration, Time(seconds: 6))
    }

    func testOverlayPlacementAndMove() {
        var p = makeProject([10])
        var text = Clip(kind: .text, name: "a", start: .zero, duration: Time(seconds: 3))
        text.text = TextContent(string: "a")
        let firstTrack = p.placeOverlay(text, at: Time(seconds: 1))
        var other = Clip(kind: .text, name: "b", start: .zero, duration: Time(seconds: 3))
        other.text = TextContent(string: "b")
        let secondTrack = p.placeOverlay(other, at: Time(seconds: 2))
        // 重なるので別のトラックに置かれる
        XCTAssertNotEqual(firstTrack, secondTrack)
        XCTAssertEqual(p.trackIndices(of: .video).count, 3)
        // 空いている場所へは移動できる
        XCTAssertTrue(p.move(clipID: other.id, toTrack: firstTrack, start: Time(seconds: 5)))
        XCTAssertEqual(p.clip(other.id)?.start, Time(seconds: 5))
        XCTAssertEqual(p.locate(other.id)?.track, p.trackIndex(firstTrack))
        // 音声トラックへは映像系を置けない
        let audioTrack = p.addTrack(kind: .audio)
        XCTAssertFalse(p.move(clipID: other.id, toTrack: audioTrack, start: .zero))
    }

    func testReorderAndMoveOnMain() {
        var p = makeProject([1, 2, 3])
        let ids = p.tracks[0].clips.map { $0.id }
        p.reorderMain(clipID: ids[2], toIndex: 0)
        XCTAssertEqual(p.tracks[0].clips.map { $0.id }, [ids[2], ids[0], ids[1]])
        XCTAssertEqual(p.tracks[0].clips.map { $0.start }, [.zero, Time(seconds: 3), Time(seconds: 4)])
        // ドラッグで 1 本目の後半に落とすと 2 番目に入る
        p.move(clipID: ids[1], toTrack: p.tracks[0].id, start: Time(seconds: 2))
        XCTAssertEqual(p.tracks[0].clips.map { $0.id }, [ids[2], ids[1], ids[0]])
    }

    func testSpeedRipplesFollowingClips() {
        var p = makeProject([4, 4])
        let id = p.tracks[0].clips[0].id
        p.setSpeed(clipID: id, rate: 0.5)
        XCTAssertEqual(p.clip(id)?.duration, Time(seconds: 8))
        XCTAssertEqual(p.tracks[0].clips[1].start, Time(seconds: 8))
        p.setSpeedCurve(clipID: id, points: [SpeedPoint(0, 1), SpeedPoint(1, 3)])
        // 素材 4 秒・平均 2 倍 → 2 秒
        XCTAssertEqual(p.clip(id)!.duration.seconds, 2, accuracy: 0.001)
    }

    func testDuplicateAndFreeze() {
        var p = makeProject([4])
        let id = p.tracks[0].clips[0].id
        let copy = p.duplicate(clipID: id)
        XCTAssertNotNil(copy)
        XCTAssertEqual(p.tracks[0].clips.count, 2)
        XCTAssertEqual(p.clip(copy!)?.start, Time(seconds: 4))
        var still = MediaAsset(kind: .image, name: "f", storage: .generated)
        still.width = 1920
        still.height = 1080
        let freeze = p.insertFreezeFrame(clipID: id, at: Time(seconds: 2), image: still, length: Time(seconds: 1))
        XCTAssertNotNil(freeze)
        XCTAssertEqual(p.tracks[0].clips.count, 4)
        XCTAssertEqual(p.clip(freeze!)?.start, Time(seconds: 2))
        XCTAssertEqual(p.duration, Time(seconds: 9))
    }

    func testSnap() {
        let snapped = Project.snap(start: Time(seconds: 1.04), duration: Time(seconds: 2),
                                   candidates: [Time(seconds: 1), Time(seconds: 5)], threshold: Time(seconds: 0.1))
        XCTAssertEqual(snapped, Time(seconds: 1))
        let byEnd = Project.snap(start: Time(seconds: 2.95), duration: Time(seconds: 2),
                                 candidates: [Time(seconds: 5)], threshold: Time(seconds: 0.1))
        XCTAssertEqual(byEnd, Time(seconds: 3))
        let none = Project.snap(start: Time(seconds: 2), duration: Time(seconds: 1),
                                candidates: [Time(seconds: 5)], threshold: Time(seconds: 0.1))
        XCTAssertEqual(none, Time(seconds: 2))
    }

    func testSplitKeyframesKeepMotion() {
        var p = makeProject([4])
        let id = p.tracks[0].clips[0].id
        p.updateClip(id) { clip in
            clip.transform.scale.toggleKey(at: .zero, tolerance: .zero)
            clip.transform.scale.toggleKey(at: Time(seconds: 4), tolerance: .zero)
            clip.transform.scale.set(2, at: Time(seconds: 4), tolerance: .zero)
            clip.transform.scale.keys[0].easing = .linear
        }
        let right = p.split(clipID: id, at: Time(seconds: 1))!
        XCTAssertEqual(p.clip(id)!.transform.scale.value(at: Time(seconds: 1)), 1.25, accuracy: 0.001)
        XCTAssertEqual(p.clip(right)!.transform.scale.value(at: .zero), 1.25, accuracy: 0.001)
        XCTAssertEqual(p.clip(right)!.transform.scale.value(at: Time(seconds: 3)), 2, accuracy: 0.001)
    }

    func testUndoRedoAndSpill() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("undo-\(UUID().uuidString)")
        let history = UndoHistory(spillDirectory: dir, memoryLimit: 2)
        var p = makeProject([1])
        var states: [Project] = []
        for i in 0..<6 {
            states.append(p)
            history.record(before: p, name: "edit \(i)")
            p.name = "n\(i)"
        }
        XCTAssertEqual(history.count, 6)
        var current = p
        for i in stride(from: 5, through: 0, by: -1) {
            let previous = history.undo(current: current)
            XCTAssertNotNil(previous)
            XCTAssertEqual(previous?.name, states[i].name)
            current = previous!
        }
        XCTAssertFalse(history.canUndo)
        let redone = history.redo(current: current)
        XCTAssertEqual(redone?.name, "n0")
    }

    func testUndoCoalescing() {
        let history = UndoHistory(spillDirectory: nil)
        let p = makeProject([1])
        history.record(before: p, name: "明るさ", coalesceKey: "brightness")
        history.record(before: p, name: "明るさ", coalesceKey: "brightness")
        history.record(before: p, name: "明るさ", coalesceKey: "brightness")
        XCTAssertEqual(history.count, 1)
        history.record(before: p, name: "彩度", coalesceKey: "saturation")
        XCTAssertEqual(history.count, 2)
    }

    func testUnusedMedia() {
        var p = makeProject([1, 2])
        let unused = makeVideo(3)
        p.media.append(unused)
        XCTAssertEqual(p.unusedMediaIDs, [unused.id])
    }
}
