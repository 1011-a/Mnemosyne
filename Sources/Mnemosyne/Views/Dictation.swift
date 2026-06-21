import Foundation
import Observation
import Speech
import AVFoundation

/// On-device speech-to-text for the Ask box. Streams live partial transcriptions via
/// `onText` (the latest best guess for the current utterance), so the caller can show
/// dictation as it happens. Gracefully no-ops if permission is denied or unavailable.
@MainActor
@Observable
final class Dictation {
    private(set) var isRecording = false
    private(set) var available = SFSpeechRecognizer(locale: Locale.current)?.isAvailable ?? false

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Toggle dictation. `onText` receives the running transcription of this session.
    func toggle(onText: @escaping (String) -> Void) {
        if isRecording { stop() } else { start(onText: onText) }
    }

    private func start(onText: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor in
                guard status == .authorized else { self?.available = false; return }
                self?.beginCapture(onText: onText)
            }
        }
    }

    private func beginCapture(onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { available = false; return }
        // Reset any prior session.
        task?.cancel(); task = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buffer, _ in
            req?.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch { stop(); return }

        isRecording = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                if let result { onText(result.bestTranscription.formattedString) }
                if error != nil || (result?.isFinal ?? false) { self?.stop() }
            }
        }
    }

    func stop() {
        if engine.isRunning { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isRecording = false
    }
}
