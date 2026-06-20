import Foundation
import Speech

/// On-device speech-to-text for audio files via the Speech framework.
/// Best-effort: returns nil if unauthorized or the model isn't available, so
/// ingestion degrades gracefully (the file is simply skipped).
enum AudioTranscriber {

    static func transcribe(_ url: URL) async -> String? {
        let status = await authorize()
        guard status == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            // Hold the recognizer alive for the duration of the task.
            let holder = TaskHolder()
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if error != nil {
                    holder.finish { cont.resume(returning: nil) }
                    return
                }
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    holder.finish { cont.resume(returning: text.isEmpty ? nil : text) }
                }
            }
        }
    }

    private static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    /// Serializes the single resume and retains the recognition task.
    private final class TaskHolder: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
        private var done = false
        private let lock = NSLock()
        func finish(_ resume: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            resume()
        }
    }
}
