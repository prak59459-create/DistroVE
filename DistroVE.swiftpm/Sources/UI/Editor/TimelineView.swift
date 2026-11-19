import Combine
import SwiftUI
import UIKit

/// SwiftUI からタイムライン（UIKit）を使うための入れ物。
struct TimelineRepresentable: UIViewRepresentable {
    @ObservedObject var controller: EditorController
    let colorBlind: Bool
    let compact: Bool

    func makeUIView(context: Context) -> TimelineCanvasView {
        let view = TimelineCanvasView()
        view.controller = controller
        view.palette = TrackPalette(colorBlind: colorBlind)
        view.compact = compact
        view.attach()
        return view
    }

    func updateUIView(_ view: TimelineCanvasView, context: Context) {
        view.palette = TrackPalette(colorBlind: colorBlind)
        view.compact = compact
        view.setNeedsDisplay()
    }
}

/// タイムライン。再生位置は中央に固定し、下の帯を動かす（CapCut・VN と同じ操作感）。
/// 指 1 本でスクロール（＝スクラブ）、2 本指でゆっくり精密スクラブ、ピンチで拡大、長押しで移動・並べ替え（Q68）。
final class TimelineCanvasView: UIView, UIGestureRecognizerDelegate {
    weak var controller: EditorController?
    var palette = TrackPalette(colorBlind: false)
    var compact: Bool = false

    private var cancellables: Set<AnyCancellable> = []
    private var displayLink: CADisplayLink?

    // 寸法
    private var headerWidth: CGFloat { return compact ? 58 : 118 }
    private let rulerHeight: CGFloat = 26
    private var scrollY: CGFloat = 0

    // 操作中の状態
    private enum Drag {
        case none
        case scroll(startTime: Time, startY: CGFloat)
        case fineScrub(startTime: Time)
        case trim(clipID: UUID, edge: TrimEdge)
        case move(clipID: UUID, grabOffset: Time, duration: Time)
    }

    private var drag: Drag = .none
    private var ghost: (trackIndex: Int, start: Time, duration: Time, kind: ClipKind)?
    private var snapLine: Time?
    private var pinchStartZoom: Double = 80

    struct Row {
        let trackIndex: Int
        let y: CGFloat
        let height: CGFloat
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        backgroundColor = Theme.backgroundUI
        isAccessibilityElement = true
        accessibilityLabel = "タイムライン"
        accessibilityHint = "指 1 本で左右にスクロール、ピンチで拡大縮小、長押しでクリップを移動"

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.allowedScrollTypesMask = .all
        pan.delegate = self
        addGestureRecognizer(pan)

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(handleFineScrub(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        longPress.delegate = self
        addGestureRecognizer(longPress)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach() {
        guard let controller = controller else { return }
        controller.clock.$time
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setNeedsDisplay() }
            .store(in: &cancellables)
        controller.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in self?.setPlaying(playing) }
            .store(in: &cancellables)
    }

    /// 再生中は画面の更新に合わせて再生位置を読み、なめらかに流す。
    private func setPlaying(_ playing: Bool) {
        displayLink?.invalidate()
        displayLink = nil
        if playing {
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func step() {
        guard let controller = controller, controller.isPlaying else { return }
        let t = Time(controller.player.currentTime())
        if t != controller.clock.time {
            controller.clock.time = t
        }
    }

    // MARK: 座標

    private var playheadX: CGFloat {
        return headerWidth + (bounds.width - headerWidth) / 2
    }

    private var currentTime: Time {
        return controller?.clock.time ?? .zero
    }

    private var pointsPerSecond: CGFloat {
        return CGFloat(controller?.zoom ?? 80)
    }

    func x(for time: Time) -> CGFloat {
        return playheadX + CGFloat((time - currentTime).seconds) * pointsPerSecond
    }

    func time(at x: CGFloat) -> Time {
        return currentTime + Time(seconds: Double((x - playheadX) / pointsPerSecond))
    }

    private func rowHeight(_ kind: TrackKind) -> CGFloat {
        switch kind {
        case .video: return compact ? 50 : 58
        case .audio: return compact ? 36 : 42
        case .subtitle: return 30
        }
    }

    /// 上から：字幕 → 映像（重なりの上から順）→ 音声。
    func rows(_ project: Project) -> [Row] {
        var order: [Int] = []
        order.append(contentsOf: project.trackIndices(of: .subtitle))
        order.append(contentsOf: project.trackIndices(of: .video).reversed())
        order.append(contentsOf: project.trackIndices(of: .audio))
        var result: [Row] = []
        var y: CGFloat = rulerHeight + 6 - scrollY
        for index in order {
            let h: CGFloat = rowHeight(project.tracks[index].kind)
            result.append(Row(trackIndex: index, y: y, height: h))
            y += h + 4
        }
        return result
    }

    private func contentHeight(_ project: Project) -> CGFloat {
        var total: CGFloat = rulerHeight + 6
        for track in project.tracks {
            total += rowHeight(track.kind) + 4
        }
        return total + 40
    }

    private func row(at y: CGFloat, rows: [Row]) -> Row? {
        return rows.first { y >= $0.y && y < $0.y + $0.height }
    }

    // MARK: 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let controller = controller else { return }
        let project: Project = controller.project
        ctx.setFillColor(Theme.backgroundUI.cgColor)
        ctx.fill(bounds)
        let allRows: [Row] = rows(project)
        let visibleStart: Time = time(at: headerWidth)
        let visibleEnd: Time = time(at: bounds.width)

        // 再生範囲（Q40: 範囲指定）
        if let range = project.playRange {
            let a: CGFloat = max(headerWidth, x(for: range.start))
            let b: CGFloat = min(bounds.width, x(for: range.end))
            if b > a {
                ctx.setFillColor(Theme.accentUI.withAlphaComponent(0.08).cgColor)
                ctx.fill(CGRect(x: a, y: 0, width: b - a, height: bounds.height))
            }
        }
        // 全体の終わり
        let endX: CGFloat = x(for: project.duration)
        if endX < bounds.width && endX > headerWidth {
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.25).cgColor)
            ctx.fill(CGRect(x: endX, y: rulerHeight, width: bounds.width - endX, height: bounds.height))
        }

        for row in allRows where row.y + row.height > rulerHeight && row.y < bounds.height {
            drawRow(ctx, row: row, project: project, from: visibleStart, to: visibleEnd)
        }
        if let g = ghost, let row = allRows.first(where: { $0.trackIndex == g.trackIndex }) {
            let frame = CGRect(x: x(for: g.start), y: row.y, width: CGFloat(g.duration.seconds) * pointsPerSecond, height: row.height)
            ctx.setFillColor(palette.color(for: g.kind).withAlphaComponent(0.45).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
            ctx.fillPath()
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 6).cgPath)
            ctx.strokePath()
        }
        if let snap = snapLine {
            let sx: CGFloat = x(for: snap)
            ctx.setStrokeColor(UIColor.systemYellow.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: sx, y: rulerHeight))
            ctx.addLine(to: CGPoint(x: sx, y: bounds.height))
            ctx.strokePath()
        }
        drawRuler(ctx, project: project, from: visibleStart, to: visibleEnd)
        drawHeaders(ctx, rows: allRows, project: project)
        // 再生位置
        ctx.setFillColor(Theme.playheadUI.cgColor)
        ctx.fill(CGRect(x: playheadX - 1, y: 0, width: 2, height: bounds.height))
        let triangle = UIBezierPath()
        triangle.move(to: CGPoint(x: playheadX - 6, y: 0))
        triangle.addLine(to: CGPoint(x: playheadX + 6, y: 0))
        triangle.addLine(to: CGPoint(x: playheadX, y: 8))
        triangle.close()
        ctx.addPath(triangle.cgPath)
        ctx.fillPath()
    }

    private func drawRuler(_ ctx: CGContext, project: Project, from: Time, to: Time) {
        ctx.setFillColor(Theme.panelUI.cgColor)
        ctx.fill(CGRect(x: headerWidth, y: 0, width: bounds.width - headerWidth, height: rulerHeight))
        let step: Double = rulerStep()
        let startSeconds: Double = max(0, (from.seconds / step).rounded(.down) * step)
        var s: Double = startSeconds
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.subtextUI
        ]
        ctx.setStrokeColor(Theme.lineUI.cgColor)
        ctx.setLineWidth(1)
        while s <= to.seconds + step {
            let px: CGFloat = x(for: Time(seconds: s))
            if px >= headerWidth {
                ctx.move(to: CGPoint(x: px, y: rulerHeight - 8))
                ctx.addLine(to: CGPoint(x: px, y: rulerHeight))
                let label: String = TimelineCanvasView.label(seconds: s, step: step, fps: project.canvas.fps)
                (label as NSString).draw(at: CGPoint(x: px + 3, y: 3), withAttributes: attributes)
            }
            let minor: Double = step / 4
            for k in 1..<4 {
                let mx: CGFloat = x(for: Time(seconds: s + minor * Double(k)))
                if mx >= headerWidth {
                    ctx.move(to: CGPoint(x: mx, y: rulerHeight - 4))
                    ctx.addLine(to: CGPoint(x: mx, y: rulerHeight))
                }
            }
            s += step
        }
        ctx.strokePath()
        // ビートマーカー・マーカー（Q59）
        for marker in project.markers where marker.time >= from && marker.time <= to {
            let mx: CGFloat = x(for: marker.time)
            if mx < headerWidth { continue }
            switch marker.kind {
            case .beat:
                ctx.setFillColor(palette.beat.cgColor)
                ctx.fillEllipse(in: CGRect(x: mx - 2.5, y: rulerHeight - 6, width: 5, height: 5))
            case .user, .chapter:
                ctx.setFillColor(Theme.accentUI.cgColor)
                let flag = UIBezierPath()
                flag.move(to: CGPoint(x: mx, y: 2))
                flag.addLine(to: CGPoint(x: mx + 8, y: 6))
                flag.addLine(to: CGPoint(x: mx, y: 10))
                flag.close()
                ctx.addPath(flag.cgPath)
                ctx.fillPath()
                ctx.fill(CGRect(x: mx - 0.5, y: 2, width: 1, height: rulerHeight - 2))
            }
        }
    }

    private func rulerStep() -> Double {
        let pps: Double = Double(pointsPerSecond)
        let candidates: [Double] = [1.0 / 30.0, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        for c in candidates where c * pps >= 70 {
            return c
        }
        return 1200
    }

    static func label(seconds: Double, step: Double, fps: Double) -> String {
        if step < 1 {
            let whole: Int = Int(seconds)
            let frame: Int = Int(((seconds - Double(whole)) * fps).rounded())
            if frame == 0 { return Time(seconds: seconds).shortLabel }
            return "\(frame)f"
        }
        return Time(seconds: seconds).shortLabel
    }

    private func drawRow(_ ctx: CGContext, row: Row, project: Project, from: Time, to: Time) {
        let track: Track = project.tracks[row.trackIndex]
        let lane = CGRect(x: headerWidth, y: row.y, width: bounds.width - headerWidth, height: row.height)
        ctx.setFillColor(Theme.panelUI.withAlphaComponent(0.55).cgColor)
        ctx.fill(lane)
        if track.kind == .subtitle {
            drawCues(ctx, row: row, track: track, from: from, to: to)
            return
        }
        guard let controller = controller else { return }
        for clip in track.clips where clip.end >= from && clip.start <= to {
            let frame = CGRect(x: x(for: clip.start), y: row.y, width: max(2, CGFloat(clip.duration.seconds) * pointsPerSecond), height: row.height)
            let visible: CGRect = frame.intersection(CGRect(x: headerWidth, y: 0, width: bounds.width - headerWidth, height: bounds.height))
            if visible.isEmpty { continue }
            drawClip(ctx, clip: clip, frame: frame, visible: visible, project: project, track: track,
                     selected: controller.selectedClipIDs.contains(clip.id))
        }
        // トランジションの印
        if row.trackIndex == project.mainTrackIndex {
            for clip in track.clips where clip.transitionIn != nil && clip.start >= from && clip.start <= to {
                let cx: CGFloat = x(for: clip.start)
                let r = CGRect(x: cx - 9, y: row.y + row.height / 2 - 9, width: 18, height: 18)
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fillEllipse(in: r)
                ctx.setFillColor(UIColor.black.cgColor)
                ctx.fill(CGRect(x: cx - 4, y: row.y + row.height / 2 - 1, width: 8, height: 2))
                ctx.fill(CGRect(x: cx - 1, y: row.y + row.height / 2 - 4, width: 2, height: 8))
            }
        }
        if track.isHidden || track.isMuted {
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
            ctx.fill(lane)
        }
    }

    private func drawClip(_ ctx: CGContext, clip: Clip, frame: CGRect, visible: CGRect, project: Project, track: Track, selected: Bool) {
        let base: UIColor = palette.color(for: clip.kind)
        let path = UIBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 1), cornerRadius: 6)
        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()
        ctx.setFillColor(base.withAlphaComponent(0.85).cgColor)
        ctx.fill(frame)
        // コマ（フィルムストリップ）
        if clip.kind == .video || clip.kind == .image || clip.kind == .gif, let asset = project.asset(clip.mediaID),
           let strip = ThumbnailStore.shared.strip(asset.id), let first = strip.images.first {
            let tileHeight: CGFloat = frame.height - 2
            let imageWidth: CGFloat = CGFloat(first.width)
            let imageHeight: CGFloat = CGFloat(max(1, first.height))
            let aspect: CGFloat = imageWidth / imageHeight
            let tileWidth: CGFloat = max(16, tileHeight * aspect)
            let offset: CGFloat = visible.minX - frame.minX
            let phase: CGFloat = offset.truncatingRemainder(dividingBy: tileWidth)
            var tx: CGFloat = max(frame.minX, visible.minX - phase)
            let map = SpeedMap(settings: clip.speed)
            while tx < visible.maxX {
                let distance: CGFloat = tx - frame.minX
                let localSeconds: Double = Double(distance / pointsPerSecond)
                let local = Time(seconds: localSeconds)
                let sourceTime: Time = clip.sourceStart + map.sourceOffset(atTimeline: local, timelineDuration: clip.duration)
                let source: Double = sourceTime.seconds
                if let image = strip.image(atSeconds: source) {
                    ctx.saveGState()
                    ctx.translateBy(x: tx, y: frame.minY + 1 + tileHeight)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(image, in: CGRect(x: 0, y: 0, width: tileWidth, height: tileHeight))
                    ctx.restoreGState()
                }
                tx += tileWidth
            }
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.18).cgColor)
            ctx.fill(frame)
        }
        // 波形（Q59）
        if clip.kind == .audio || (clip.kind == .video && track.kind == .video && project.asset(clip.mediaID)?.hasAudio == true),
           let asset = project.asset(clip.mediaID), let features = AudioAnalyzer.cached(asset) {
            drawWaveform(ctx, features: features, clip: clip, frame: frame, visible: visible, onVideo: clip.kind == .video)
        }
        // 名前とバッジ
        var title: String = clip.name
        if clip.kind == .text || clip.kind == .sticker, let t = clip.text { title = t.string.replacingOccurrences(of: "\n", with: " ") }
        let badges: [String] = clip.badges
        if !badges.isEmpty { title += "  " + badges.joined(separator: " ") }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let labelX: CGFloat = max(frame.minX + 6, visible.minX + 4)
        if frame.maxX - labelX > 24 {
            let labelRect = CGRect(x: labelX, y: frame.minY + 3, width: frame.maxX - labelX - 4, height: 14)
            (title as NSString).draw(with: labelRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes, context: nil)
        }
        // キーフレーム（Q44）
        drawKeyframes(ctx, clip: clip, frame: frame)
        ctx.restoreGState()
        if selected {
            ctx.setStrokeColor(UIColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
            // トリムの取っ手
            ctx.setFillColor(UIColor.white.cgColor)
            let handleW: CGFloat = 10
            let left = CGRect(x: frame.minX, y: frame.minY + 1, width: handleW, height: frame.height - 2)
            let right = CGRect(x: frame.maxX - handleW, y: frame.minY + 1, width: handleW, height: frame.height - 2)
            ctx.addPath(UIBezierPath(roundedRect: left, byRoundingCorners: [.topLeft, .bottomLeft], cornerRadii: CGSize(width: 5, height: 5)).cgPath)
            ctx.addPath(UIBezierPath(roundedRect: right, byRoundingCorners: [.topRight, .bottomRight], cornerRadii: CGSize(width: 5, height: 5)).cgPath)
            ctx.fillPath()
            ctx.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
            ctx.fill(CGRect(x: left.midX - 1, y: left.midY - 7, width: 2, height: 14))
            ctx.fill(CGRect(x: right.midX - 1, y: right.midY - 7, width: 2, height: 14))
        }
    }

    private func drawWaveform(_ ctx: CGContext, features: AudioFeatures, clip: Clip, frame: CGRect, visible: CGRect, onVideo: Bool) {
        let columns: Int = max(1, Int(visible.width / 2))
        let map = SpeedMap(settings: clip.speed)
        let height: CGFloat = onVideo ? frame.height * 0.35 : frame.height - 18
        let baseline: CGFloat = frame.maxY - 2
        ctx.setFillColor(UIColor.white.withAlphaComponent(onVideo ? 0.45 : 0.7).cgColor)
        for i in 0..<columns {
            let px: CGFloat = visible.minX + CGFloat(i) * 2
            let a = Time(seconds: Double((px - frame.minX) / pointsPerSecond))
            let b = Time(seconds: Double((px + 2 - frame.minX) / pointsPerSecond))
            let sa: Double = (clip.sourceStart + map.sourceOffset(atTimeline: a, timelineDuration: clip.duration)).seconds
            let sb: Double = (clip.sourceStart + map.sourceOffset(atTimeline: b, timelineDuration: clip.duration)).seconds
            let values: [Float] = features.waveform(from: min(sa, sb), to: max(sa, sb) + 0.001, count: 1)
            let level: CGFloat = CGFloat(min(1, (values.first ?? 0) * Float(clip.audio.volume.value(at: a))))
            let h: CGFloat = max(1, level * height)
            ctx.fill(CGRect(x: px, y: baseline - h, width: 1.4, height: h))
        }
    }

    private func drawKeyframes(_ ctx: CGContext, clip: Clip, frame: CGRect) {
        var times: [Time] = []
        let params: [Param] = [clip.transform.positionX, clip.transform.positionY, clip.transform.scale, clip.transform.rotation,
                               clip.transform.opacity, clip.transform.rotationX, clip.transform.rotationY, clip.audio.volume]
        for p in params {
            for k in p.keys { times.append(k.time) }
        }
        for (_, p) in clip.color.values {
            for k in p.keys { times.append(k.time) }
        }
        if times.isEmpty { return }
        ctx.setFillColor(UIColor.white.cgColor)
        for t in times {
            let kx: CGFloat = frame.minX + CGFloat(t.seconds) * pointsPerSecond
            let y: CGFloat = frame.maxY - 7
            let diamond = UIBezierPath()
            diamond.move(to: CGPoint(x: kx, y: y - 4))
            diamond.addLine(to: CGPoint(x: kx + 4, y: y))
            diamond.addLine(to: CGPoint(x: kx, y: y + 4))
            diamond.addLine(to: CGPoint(x: kx - 4, y: y))
            diamond.close()
            ctx.addPath(diamond.cgPath)
        }
        ctx.fillPath()
    }

    private func drawCues(_ ctx: CGContext, row: Row, track: Track, from: Time, to: Time) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: UIColor.black
        ]
        let selectedID: UUID? = controller?.selectedCueID
        for cue in track.cues {
            let start: Time = cue.start + track.subtitleOffset
            let end: Time = cue.end + track.subtitleOffset
            if end < from || start > to { continue }
            let frame = CGRect(x: x(for: start), y: row.y + 2, width: max(4, CGFloat((end - start).seconds) * pointsPerSecond), height: row.height - 4)
            let color: UIColor = cue.speaker > 0 ? UIColor(track.subtitleStyle.color(forSpeaker: cue.speaker).color) : palette.subtitle
            ctx.setFillColor(color.withAlphaComponent(0.9).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 4).cgPath)
            ctx.fillPath()
            if cue.id == selectedID {
                ctx.setStrokeColor(UIColor.white.cgColor)
                ctx.setLineWidth(2)
                ctx.addPath(UIBezierPath(roundedRect: frame, cornerRadius: 4).cgPath)
                ctx.strokePath()
            }
            if frame.width > 20 {
                (cue.text as NSString).draw(with: frame.insetBy(dx: 4, dy: 5), options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: attributes, context: nil)
            }
        }
    }

    private func drawHeaders(_ ctx: CGContext, rows: [Row], project: Project) {
        ctx.setFillColor(Theme.panelUI.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: headerWidth, height: bounds.height))
        ctx.setFillColor(Theme.lineUI.cgColor)
        ctx.fill(CGRect(x: headerWidth - 1, y: 0, width: 1, height: bounds.height))
        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.textUI
        ]
        for row in rows where row.y + row.height > rulerHeight {
            let track: Track = project.tracks[row.trackIndex]
            if !compact {
                let nameRect = CGRect(x: 8, y: row.y + 4, width: headerWidth - 12, height: 14)
                (track.name as NSString).draw(with: nameRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: nameAttributes, context: nil)
            }
            for (i, button) in headerButtons(track).enumerated() {
                let r: CGRect = headerButtonRect(row: row, index: i)
                let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                if let image = UIImage(systemName: button.symbol, withConfiguration: config)?.withTintColor(button.active ? Theme.accentUI : Theme.subtextUI, renderingMode: .alwaysOriginal) {
                    image.draw(in: r.insetBy(dx: (r.width - image.size.width) / 2, dy: (r.height - image.size.height) / 2))
                }
            }
        }
        ctx.setFillColor(Theme.panelUI.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: headerWidth, height: rulerHeight))
        let timeAttributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.textUI
        ]
        let fps: Double = project.canvas.fps
        (currentTime.timecode(fps: fps) as NSString).draw(at: CGPoint(x: 6, y: 6), withAttributes: timeAttributes)
    }

    private struct HeaderButton {
        let symbol: String
        let active: Bool
        let action: Int
    }

    private func headerButtons(_ track: Track) -> [HeaderButton] {
        var result: [HeaderButton] = []
        switch track.kind {
        case .video:
            result.append(HeaderButton(symbol: track.isHidden ? "eye.slash" : "eye", active: track.isHidden, action: 0))
            result.append(HeaderButton(symbol: track.isMuted ? "speaker.slash" : "speaker.wave.2", active: track.isMuted, action: 1))
        case .audio:
            result.append(HeaderButton(symbol: track.isMuted ? "speaker.slash" : "speaker.wave.2", active: track.isMuted, action: 1))
        case .subtitle:
            result.append(HeaderButton(symbol: track.isHidden ? "eye.slash" : "captions.bubble", active: track.isHidden, action: 0))
        }
        result.append(HeaderButton(symbol: track.isLocked ? "lock" : "lock.open", active: track.isLocked, action: 2))
        return result
    }

    private func headerButtonRect(row: Row, index: Int) -> CGRect {
        let size: CGFloat = 24
        let y: CGFloat = compact ? row.y + (row.height - size) / 2 : row.y + row.height - size - 2
        if compact {
            return CGRect(x: 4 + CGFloat(index) * 17, y: y, width: 17, height: size)
        }
        return CGRect(x: 6 + CGFloat(index) * (size + 4), y: y, width: size, height: size)
    }

    // MARK: 当たり判定

    private struct Hit {
        var row: Row?
        var clip: Clip?
        var cue: SubtitleCue?
        var trimEdge: TrimEdge?
        var headerAction: Int?
    }

    private func hitTest(_ point: CGPoint) -> Hit {
        var hit = Hit()
        guard let controller = controller else { return hit }
        let project: Project = controller.project
        let allRows: [Row] = rows(project)
        guard let row = row(at: point.y, rows: allRows) else { return hit }
        hit.row = row
        let track: Track = project.tracks[row.trackIndex]
        if point.x < headerWidth {
            for (i, button) in headerButtons(track).enumerated() where headerButtonRect(row: row, index: i).insetBy(dx: -4, dy: -6).contains(point) {
                hit.headerAction = button.action
            }
            return hit
        }
        let t: Time = time(at: point.x)
        if track.kind == .subtitle {
            hit.cue = track.cues.first { t >= $0.start + track.subtitleOffset && t < $0.end + track.subtitleOffset }
            return hit
        }
        // 選択中のクリップの端は少し外側まで掴める
        for clip in track.clips where controller.selectedClipIDs.contains(clip.id) {
            let left: CGFloat = x(for: clip.start)
            let right: CGFloat = x(for: clip.end)
            if abs(point.x - left) < 16 && point.x < right - 4 {
                hit.clip = clip
                hit.trimEdge = .leading
                return hit
            }
            if abs(point.x - right) < 16 && point.x > left + 4 {
                hit.clip = clip
                hit.trimEdge = .trailing
                return hit
            }
        }
        hit.clip = track.clips.first { $0.range.contains(t) }
        return hit
    }

    // MARK: 操作

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let controller = controller else { return }
        let point: CGPoint = g.location(in: self)
        if point.y < rulerHeight && point.x > headerWidth {
            controller.pause()
            controller.seek(to: time(at: point.x))
            return
        }
        let hit: Hit = hitTest(point)
        if let action = hit.headerAction, let row = hit.row {
            let track: Track = controller.project.tracks[row.trackIndex]
            switch action {
            case 0: controller.toggleTrack(track.id, hidden: !track.isHidden)
            case 1: controller.toggleTrack(track.id, muted: !track.isMuted)
            default: controller.toggleTrack(track.id, locked: !track.isLocked)
            }
            return
        }
        if let cue = hit.cue {
            controller.selectCue(cue.id)
        } else if let clip = hit.clip {
            controller.select(clip.id)
        } else {
            controller.select(nil)
        }
        setNeedsDisplay()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        guard let controller = controller else { return }
        let point: CGPoint = g.location(in: self)
        switch g.state {
        case .began:
            let hit: Hit = hitTest(point)
            if let clip = hit.clip, let edge = hit.trimEdge, !(controller.project.tracks[hit.row?.trackIndex ?? 0].isLocked) {
                drag = .trim(clipID: clip.id, edge: edge)
                controller.pause()
            } else {
                drag = .scroll(startTime: controller.clock.time, startY: scrollY)
                controller.beginScrub()
            }
        case .changed:
            let translation: CGPoint = g.translation(in: self)
            switch drag {
            case .scroll(let startTime, let startY):
                let delta: Double = Double(-translation.x / pointsPerSecond)
                controller.seek(to: startTime + Time(seconds: delta), precise: false)
                let maxScroll: CGFloat = max(0, contentHeight(controller.project) - bounds.height)
                scrollY = min(maxScroll, max(0, startY - translation.y))
            case .trim(let clipID, let edge):
                var target: Time = time(at: point.x)
                let candidates: [Time] = controller.snapCandidates(excluding: [clipID])
                let threshold = Time(seconds: Double(10 / pointsPerSecond))
                let snapped: Time = Project.snap(time: target, candidates: candidates, threshold: threshold)
                snapLine = snapped != target ? snapped : nil
                target = snapped
                controller.trim(clipID, edge: edge, to: target)
            default:
                break
            }
            setNeedsDisplay()
        case .ended, .cancelled, .failed:
            if case .scroll = drag { controller.endScrub() }
            if case .trim = drag { controller.refreshFrame() }
            drag = .none
            snapLine = nil
            setNeedsDisplay()
        default:
            break
        }
    }

    @objc private func handleFineScrub(_ g: UIPanGestureRecognizer) {
        guard let controller = controller else { return }
        switch g.state {
        case .began:
            drag = .fineScrub(startTime: controller.clock.time)
            controller.beginScrub()
        case .changed:
            if case .fineScrub(let start) = drag {
                let delta: Double = Double(-g.translation(in: self).x / pointsPerSecond) * 0.2
                controller.seek(to: (start + Time(seconds: delta)).snappedToFrame(fps: controller.project.canvas.fps), precise: true)
            }
        default:
            controller.endScrub()
            drag = .none
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        guard let controller = controller else { return }
        switch g.state {
        case .began:
            pinchStartZoom = controller.zoom
        case .changed:
            controller.zoom = min(1200, max(4, pinchStartZoom * Double(g.scale)))
            setNeedsDisplay()
        default:
            break
        }
    }

    /// 長押しでクリップを持ち上げ、そのまま別の位置・トラックへ動かす（Q33, Q68）。
    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard let controller = controller else { return }
        let point: CGPoint = g.location(in: self)
        let project: Project = controller.project
        switch g.state {
        case .began:
            let hit: Hit = hitTest(point)
            guard let clip = hit.clip, let row = hit.row, !project.tracks[row.trackIndex].isLocked else { return }
            controller.pause()
            controller.select(clip.id)
            drag = .move(clipID: clip.id, grabOffset: time(at: point.x) - clip.start, duration: clip.duration)
            ghost = (row.trackIndex, clip.start, clip.duration, clip.kind)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            guard case .move(let clipID, let grab, let duration) = drag, let clip = project.clip(clipID) else { return }
            let allRows: [Row] = rows(project)
            var targetTrack: Int = ghost?.trackIndex ?? 0
            if let row = row(at: point.y, rows: allRows) {
                let kind: TrackKind = project.tracks[row.trackIndex].kind
                if kind != .subtitle && (kind == .audio) == (clip.kind == .audio) {
                    targetTrack = row.trackIndex
                }
            }
            var start: Time = max(.zero, time(at: point.x) - grab)
            let candidates: [Time] = controller.snapCandidates(excluding: [clipID])
            let threshold = Time(seconds: Double(10 / pointsPerSecond))
            let snapped: Time = Project.snap(start: start, duration: duration, candidates: candidates, threshold: threshold)
            if snapped != start {
                snapLine = candidates.contains(snapped) ? snapped : snapped + duration
            } else {
                snapLine = nil
            }
            start = snapped
            ghost = (targetTrack, start, duration, clip.kind)
            // 端に近づいたら自動でスクロール
            if point.x > bounds.width - 40 {
                controller.seek(to: controller.clock.time + Time(seconds: 0.1), precise: false)
            } else if point.x < headerWidth + 40 {
                controller.seek(to: controller.clock.time - Time(seconds: 0.1), precise: false)
            }
            setNeedsDisplay()
        case .ended:
            if case .move(let clipID, _, _) = drag, let placed = ghost {
                let trackID: UUID = project.tracks[placed.trackIndex].id
                controller.move(clipID, to: trackID, start: placed.start)
            }
            drag = .none
            ghost = nil
            snapLine = nil
            setNeedsDisplay()
        default:
            drag = .none
            ghost = nil
            snapLine = nil
            setNeedsDisplay()
        }
    }

    @objc private func handleHover(_ g: UIHoverGestureRecognizer) {
        // マウス・トラックパッドで端に重ねたときにカーソルの代わりに再描画だけ行う
        if g.state == .changed { return }
    }
}
