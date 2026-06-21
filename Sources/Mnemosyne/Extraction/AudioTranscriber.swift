import Foundation
import Speech

/// On-device speech-to-text for audio files via the Speech framework.
/// Best-effort: returns nil if unauthorized or the model isn't available, so
/// ingestion degrades gracefully (the file is simply skipped).
enum AudioTranscriber {

    /// Transcribe an audio file, giving up after `timeout` seconds. The timeout is
    /// essential: on-device recognition runs roughly in real time, and a long file —
    /// especially MUSIC, which has no speech to transcribe — would otherwise hold up the
    /// whole ingest on one file (the "stuck" symptom). On timeout the recognition task is
    /// cancelled and the file is skipped (returns nil), so ingest moves on.
    static func transcribe(_ url: URL, timeout: TimeInterval = 45) async -> String? {
        let status = await authorize()
        guard status == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let holder = TaskHolder()
            holder.resume = { cont.resume(returning: $0) }
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if error != nil { holder.finish(nil); return }
                if let result, result.isFinal {
                    let text = result.bestTranscription.formattedString
                    holder.finish(text.isEmpty ? nil : text)
                }
            }
            // Watchdog: give up (and cancel the task) so one file can't block ingest.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                holder.finish(nil)
            }
        }
    }

    private static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    /// Resumes the continuation exactly once (from the recognizer callback OR the
    /// timeout watchdog), cancelling the recognition task on the way out.
    private final class TaskHolder: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
        var resume: ((String?) -> Void)?
        private var done = false
        private let lock = NSLock()
        func finish(_ value: String?) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            task?.cancel()
            resume?(value)
            resume = nil
        }
    }
}
