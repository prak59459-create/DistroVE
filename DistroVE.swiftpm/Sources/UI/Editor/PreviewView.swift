import AVFoundation
import SwiftUI
import UIKit

/// AVPlayerLayer を表示する UIView。合成結果（独自合成）がそのまま映る。
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }
}

struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }
}

/// プレビュー。選んだクリップは指で動かす・ピンチで拡大・回転できる（Q35, Q62）。
struct PreviewArea: View {
    @ObservedObject var controller: EditorController

    @State private var dragBase: Transform?
    @State private var drag: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var twist: Angle = .zero

    var body: some View {
        GeometryReader { geo in
            let rect: CGRect = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                Theme.background
                PlayerLayerRepresentable(player: controller.player)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .accessibilityLabel("プレビュー")
                if let clip = controller.selectedClip, clip.kind.isVisual {
                    SelectionOutline(clip: clip, canvas: rect, project: controller.project, time: controller.currentTime)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(transformGesture(rect))
            .onTapGesture(count: 2) {
                controller.togglePlay()
            }
        }
    }

    private func fitted(in size: CGSize) -> CGRect {
        let canvas: CanvasSettings = controller.project.canvas
        let aspect: CGFloat = CGFloat(canvas.width) / CGFloat(max(1, canvas.height))
        var w: CGFloat = size.width
        var h: CGFloat = w / aspect
        if h > size.height {
            h = size.height
            w = h * aspect
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func transformGesture(_ rect: CGRect) -> some Gesture {
        let dragGesture = DragGesture(minimumDistance: 2)
            .onChanged { value in
                begin()
                drag = value.translation
                update(rect)
            }
            .onEnded { _ in end() }
        let magnify = MagnificationGesture()
            .onChanged { value in
                begin()
                pinch = value
                update(rect)
            }
            .onEnded { _ in end() }
        let rotate = RotationGesture()
            .onChanged { value in
                begin()
                twist = value
                update(rect)
            }
            .onEnded { _ in end() }
        return dragGesture.simultaneously(with: magnify.simultaneously(with: rotate))
    }

    private func begin() {
        if dragBase != nil { return }
        guard let clip = controller.selectedClip, clip.kind.isVisual else { return }
        controller.pause()
        dragBase = clip.transform
    }

    private func update(_ rect: CGRect) {
        guard let base = dragBase else { return }
        let dx: Double = Double(drag.width / max(1, rect.width))
        let dy: Double = Double(drag.height / max(1, rect.height))
        controller.applyCanvasGesture(dx: dx, dy: dy, scale: Double(pinch), rotation: twist.degrees, base: base)
    }

    private func end() {
        dragBase = nil
        drag = .zero
        pinch = 1
        twist = .zero
    }
}

/// 選んだクリップの枠（おおよその位置と大きさ）。
struct SelectionOutline: View {
    let clip: Clip
    let canvas: CGRect
    let project: Project
    let time: Time

    var body: some View {
        let local: Time = clip.localTime(time)
        let size: CGSize = outlineSize()
        let scale: CGFloat = CGFloat(clip.transform.scale.value(at: local))
        let x: CGFloat = canvas.midX + CGFloat(clip.transform.positionX.value(at: local)) * canvas.width
        let y: CGFloat = canvas.midY + CGFloat(clip.transform.positionY.value(at: local)) * canvas.height
        Rectangle()
            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .frame(width: max(8, size.width * scale), height: max(8, size.height * scale))
            .rotationEffect(.degrees(clip.transform.rotation.value(at: local)))
            .position(x: x, y: y)
    }

    private func outlineSize() -> CGSize {
        switch clip.kind {
        case .video, .image, .gif:
            guard let asset = project.asset(clip.mediaID), asset.width > 0, asset.height > 0 else { return canvas.size }
            let w: CGFloat = CGFloat(asset.width)
            let h: CGFloat = CGFloat(asset.height)
            let s: CGFloat
            switch clip.fitMode {
            case .fit: s = min(canvas.width / w, canvas.height / h)
            case .fill: s = max(canvas.width / w, canvas.height / h)
            case .stretch: return canvas.size
            }
            return CGSize(width: w * s, height: h * s)
        case .text, .sticker:
            let size: CGFloat = CGFloat(clip.text?.size ?? 0.07) * canvas.height
            let count: CGFloat = CGFloat(min(16, max(2, clip.text?.string.count ?? 4)))
            return CGSize(width: min(canvas.width * 0.9, size * count * 0.9), height: size * 1.4)
        case .shape:
            let h: CGFloat = CGFloat(clip.shape?.size ?? 0.3) * min(canvas.width, canvas.height)
            return CGSize(width: h * CGFloat(clip.shape?.aspect ?? 1), height: h)
        case .object3D:
            let h: CGFloat = CGFloat(clip.object3D?.size ?? 0.3) * canvas.height
            let letters: CGFloat = CGFloat(min(10, max(1, clip.object3D?.text.count ?? 1)))
            let aspect: CGFloat = clip.object3D?.kind == .text ? letters * 0.6 : 1
            return CGSize(width: min(canvas.width, h * aspect), height: h)
        default:
            return canvas.size
        }
    }
}

/// 再生の操作（Q40: 原寸・低画質・コマ送り・範囲指定・ループ）。
struct TransportBar: View {
    @ObservedObject var controller: EditorController
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(spacing: 14) {
            Text(clock.time.timecode(fps: controller.project.canvas.fps))
                .font(.system(.footnote, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.text)
            Text("/ " + controller.project.duration.timecode(fps: controller.project.canvas.fps))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.subtext)
            Spacer()
            Button { controller.step(-1) } label: { DVImage("playback.previousFrame") }
                .accessibilityLabel("1 コマ戻る")
            Button { controller.togglePlay() } label: {
                DVImage(controller.isPlaying ? "playback.pause" : "playback.play")
                    .font(.title2)
            }
            .accessibilityLabel(controller.isPlaying ? "停止" : "再生")
            Button { controller.step(1) } label: { DVImage("playback.nextFrame") }
                .accessibilityLabel("1 コマ進む")
            Spacer()
            Button { controller.loop.toggle() } label: {
                DVImage("playback.loop")
                    .foregroundStyle(controller.loop ? Theme.accent : Theme.text)
            }
            .accessibilityLabel("ループ再生")
            rangeMenu
            qualityMenu
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.panel)
    }

    private var rangeMenu: some View {
        Menu {
            Button("ここを開始にする（I）") { controller.setInPoint() }
            Button("ここを終了にする（O）") { controller.setOutPoint() }
            if controller.project.playRange != nil {
                Button("範囲を解除", role: .destructive) { controller.clearRange() }
            }
        } label: {
            DVImage(controller.project.playRange == nil ? "playback.range" : "playback.rangeOn")
                .foregroundStyle(controller.project.playRange == nil ? Theme.text : Theme.accent)
        }
        .accessibilityLabel("範囲指定")
    }

    private var qualityMenu: some View {
        Menu {
            Picker("プレビューの画質", selection: $controller.quality) {
                ForEach(PreviewQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            Toggle("プロキシで再生（軽い）", isOn: $controller.useProxies)
        } label: {
            HStack(spacing: 3) {
                DVImage(controller.reducedForThermal ? "playback.thermal" : "playback.quality")
                Text(controller.quality.label).font(.caption)
            }
        }
        .accessibilityLabel("プレビューの画質")
    }
}
