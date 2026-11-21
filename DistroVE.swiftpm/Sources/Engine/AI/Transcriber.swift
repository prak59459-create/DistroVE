#if canImport(AVFoundation) && canImport(Speech)
import AVFoundation
import Foundation
import Speech

/// 自動字幕（Q45, Q56）。Speech フレームワークを使い、対応端末では端末内で文字に起こす。
/// 端末内で処理できないときは、利用者が許可した場合だけ Apple のサーバーを使う（第 2 章の方針）。
enum Transcriber {
    static func authorize() async -> Bool {
        let current: SFSpeechRecognizerAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        if current == .denied || current == .restricted { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func supportsOnDevice(_ locale: Locale) -> Bool {
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// url の音声（range は素材上の区間）を単語ごとの時刻付きで返す。時刻は range の先頭からの秒。
    static func transcribe(url: URL, range: TimeRange, locale: Locale, allowServer: Bool,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> [AutoEdit.Word] {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            throw EngineError.unsupported("この言語の文字起こし")
        }
        let onDevice: Bool = recognizer.supportsOnDeviceRecognition
        if !onDevice && !allowServer {
            throw EngineError.notAuthorized("この端末は端末内の文字起こしに対応していません。サーバーでの処理を許可してください。")
        }
        if !recognizer.isAvailable {
            throw EngineError.unsupported("音声認識が今は使えません")
        }
        // 長い音声は 50 秒ずつに分ける
        let chunk = Time(seconds: 50)
        var words: [AutoEdit.Word] = []
        var offset: Time = .zero
        while offset < range.duration {
            if Task.isCancelled { throw EngineError.cancelled }
            let length: Time = min(chunk, range.duration - offset)
            let piece = TimeRange(start: range.start + offset, duration: length)
            let audio: URL = try await MediaJobs.extractAudio(from: url, range: piece)
            defer { try? FileManager.default.removeItem(at: audio) }
            let found: [AutoEdit.Word] = try await recognize(audio, recognizer: recognizer, onDevice: onDevice)
            for w in found {
                words.append(AutoEdit.Word(text: w.text, start: w.start + offset.seconds, duration: w.duration))
            }
            offset = offset + length
            progress?(offset.seconds / max(0.001, range.duration.seconds))
        }
        return words
    }

    private static func recognize(_ url: URL, recognizer: SFSpeechRecognizer, onDevice: Bool) async throws -> [AutoEdit.Word] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = onDevice
        if #available(iOS 16.0, macOS 13.0, *) {
            request.addsPunctuation = true
        }
        let done = Locked<Bool>(false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AutoEdit.Word], Error>) in
            _ = recognizer.recognitionTask(with: request) { result, error in
                if done.get() { return }
                if let error = error {
                    done.set(true)
                    let code: Int = (error as NSError).code
                    // 1110: 声が見つからない
                    if code == 1110 || code == 203 {
                        continuation.resume(returning: [])
                    } else {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                guard let result = result, result.isFinal else { return }
                done.set(true)
                var words: [AutoEdit.Word] = []
                for segment in result.bestTranscription.segments {
                    words.append(AutoEdit.Word(text: segment.substring, start: segment.timestamp, duration: segment.duration))
                }
                continuation.resume(returning: words)
            }
        }
    }
}
#endif
