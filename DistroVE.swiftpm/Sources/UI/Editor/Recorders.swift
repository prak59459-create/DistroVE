import AVFoundation
import PencilKit
import ReplayKit
import SwiftUI
import UIKit

// MARK: カメラ（Q49: アプリ内での撮影・Web カメラ）

/// アプリ内の撮影。iPadOS 17 以降は USB の外部カメラ（Web カメラ）も選べる。
@MainActor
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    @Published var devices: [AVCaptureDevice] = []
    @Published var current: AVCaptureDevice?
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    private var currentInput: AVCaptureDeviceInput?
    private var finished: ((URL?) -> Void)?

    func start() {
        Task {
            let video: Bool = await AVCaptureDevice.requestAccess(for: .video)
            let audio: Bool = await AVCaptureDevice.requestAccess(for: .audio)
            if !video {
                errorMessage = "カメラの使用が許可されていません（設定 App で変更できます）。"
                return
            }
            configure(withAudio: audio)
        }
    }

    private func configure(withAudio: Bool) {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .external],
                                                         mediaType: .video, position: .unspecified)
        devices = discovery.devices
        session.beginConfiguration()
        session.sessionPreset = .high
        if let device = devices.first(where: { $0.position == .back }) ?? devices.first {
            select(device)
        }
        if withAudio, let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }
        session.commitConfiguration()
        let running: AVCaptureSession = session
        Task.detached {
            running.startRunning()
        }
    }

    func select(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        if let old = currentInput { session.removeInput(old) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            current = device
        }
        session.commitConfiguration()
    }

    func toggleRecording(_ completion: @escaping (URL?) -> Void) {
        if isRecording {
            movieOutput.stopRecording()
            return
        }
        let url: URL = AppPaths.cacheFolder("Import").appendingPathComponent("camera-\(Int(Date().timeIntervalSince1970)).mov")
        finished = completion
        movieOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
    }

    func stop() {
        if isRecording { movieOutput.stopRecording() }
        let running: AVCaptureSession = session
        Task.detached {
            running.stopRunning()
        }
    }

    fileprivate func didFinish(_ url: URL?) {
        isRecording = false
        finished?(url)
        finished = nil
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let ok: Bool = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        let url: URL? = ok ? outputFileURL : nil
        Task { @MainActor in
            self.didFinish(url)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { return AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { return layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct CameraRecorderView: View {
    let onFinish: (URL?) -> Void
    @StateObject private var model = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.session).ignoresSafeArea()
            VStack {
                HStack {
                    Button("閉じる") {
                        model.stop()
                        onFinish(nil)
                    }
                    Spacer()
                    if model.devices.count > 1 {
                        Menu {
                            ForEach(model.devices, id: \.uniqueID) { device in
                                Button(device.localizedName) { model.select(device) }
                            }
                        } label: {
                            Label(model.current?.localizedName ?? "カメラ", systemImage: "camera.rotate")
                        }
                    }
                }
                .padding()
                .foregroundStyle(.white)
                Spacer()
                if let message = model.errorMessage {
                    Text(message).foregroundStyle(.white).padding()
                }
                Button {
                    model.toggleRecording { url in
                        model.stop()
                        onFinish(url)
                    }
                } label: {
                    Circle()
                        .fill(model.isRecording ? Color.red : Color.white)
                        .frame(width: 72, height: 72)
                        .overlay(Circle().stroke(Color.white, lineWidth: 4).frame(width: 84, height: 84))
                }
                .accessibilityLabel(model.isRecording ? "録画を止める" : "録画を始める")
                .padding(.bottom, 30)
            }
        }
        .onAppear { model.start() }
    }
}

// MARK: ナレーション（Q51）

@MainActor
final class NarrationModel: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var level: Float = 0
    @Published var errorMessage: String?
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var url: URL?

    func start() {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                if granted {
                    self.begin()
                } else {
                    self.errorMessage = "マイクの使用が許可されていません（設定 App で変更できます）。"
                }
            }
        }
    }

    private func begin() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let target: URL = AppPaths.cacheFolder("Import").appendingPathComponent("narration-\(Int(Date().timeIntervalSince1970)).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let recorder = try AVAudioRecorder(url: target, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            url = target
            isRecording = true
            meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self, let r = self.recorder else { return }
                    r.updateMeters()
                    self.level = max(0, min(1, (r.averagePower(forChannel: 0) + 60) / 60))
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() -> URL? {
        meter?.invalidate()
        recorder?.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }
}

struct NarrationRecorderView: View {
    let onFinish: (URL?) -> Void
    @StateObject private var model = NarrationModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("ナレーションの録音").font(.headline)
            Text("録音した声は、再生位置の音声トラックに置きます。")
                .font(.footnote)
                .foregroundStyle(Theme.subtext)
            ProgressView(value: Double(model.level))
                .frame(width: 220)
            if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            HStack(spacing: 20) {
                Button("やめる") {
                    _ = model.stop()
                    onFinish(nil)
                }
                Button(model.isRecording ? "止めて追加" : "録音を始める") {
                    if model.isRecording {
                        onFinish(model.stop())
                    } else {
                        model.start()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .presentationDetents([.medium])
    }
}

// MARK: 画面録画（Q49）

/// アプリ自身の画面を録画する（ReplayKit）。
@MainActor
final class ScreenRecorderModel: ObservableObject {
    @Published var isRecording: Bool = false

    func toggle(_ completion: @escaping (URL) -> Void) {
        let recorder = RPScreenRecorder.shared()
        if isRecording {
            let url: URL = AppPaths.cacheFolder("Import").appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).mp4")
            recorder.stopRecording(withOutput: url) { error in
                Task { @MainActor in
                    self.isRecording = false
                    if error == nil { completion(url) }
                }
            }
            return
        }
        recorder.isMicrophoneEnabled = true
        recorder.startRecording { error in
            Task { @MainActor in
                self.isRecording = error == nil
            }
        }
    }
}

// MARK: 手書き（Q47）

struct DrawingSheet: View {
    let aspect: CGFloat
    let onFinish: (CGImage?) -> Void
    @State private var drawing = PKDrawing()

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let size: CGSize = fittedSize(geo.size)
                ZStack {
                    Color.black.opacity(0.85)
                    DrawingCanvas(drawing: $drawing)
                        .frame(width: size.width, height: size.height)
                        .background(Color.white.opacity(0.06))
                        .overlay(Rectangle().stroke(Theme.line))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { canvasSize = size }
            }
            .navigationTitle("手書き")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("やめる") { onFinish(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("追加") { onFinish(renderImage()) }
                        .disabled(drawing.strokes.isEmpty)
                }
            }
        }
    }

    @State private var canvasSize: CGSize = CGSize(width: 800, height: 450)

    private func fittedSize(_ available: CGSize) -> CGSize {
        var w: CGFloat = available.width - 40
        var h: CGFloat = w / max(0.1, aspect)
        if h > available.height - 40 {
            h = available.height - 40
            w = h * aspect
        }
        return CGSize(width: max(100, w), height: max(100, h))
    }

    private func renderImage() -> CGImage? {
        let rect = CGRect(origin: .zero, size: canvasSize)
        let image: UIImage = drawing.image(from: rect, scale: 2)
        return image.cgImage
    }
}

struct DrawingCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: DrawingCanvas
        let toolPicker = PKToolPicker()

        init(_ parent: DrawingCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator
        canvas.tool = PKInkingTool(.pen, color: .systemRed, width: 8)
        context.coordinator.toolPicker.setVisible(true, forFirstResponder: canvas)
        context.coordinator.toolPicker.addObserver(canvas)
        DispatchQueue.main.async {
            canvas.becomeFirstResponder()
        }
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}
