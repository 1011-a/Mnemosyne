import Foundation
import Speech

/// On-device speech-to-text for audio files via the Speech framework.
/// Best-effort: returns nil if unauthorized or the model isn't available, so
/// ingestion degrades gracefully (the file is simply skipped).
///
/// Two guards keep one file from stalling ingest (the "stuck" symptom), since on-device
/// recognition runs roughly in real time:
///  • **Quiet bail** — if no words are heard within `quietBail` seconds, the file is
///    almost certainly MUSIC or noise (no speech), so we cancel and skip it fast.
///  • **Hard cap** — long genuine speech is cut off at `maxTimeout`, returning the
///    transcript captured SO FAR (partial results) rather than losing the whole file.
enum AudioTranscriber {

    /// Transcribe with an EXTERNAL hard deadline that does NOT depend on the recognizer behaving.
    /// `transcribe` has its own internal timers, but a wedged `SFSpeechRecognizer` (seen in the
    /// wild on some audio) can deadlock so those never fire — stalling ingest indefinitely. This
    /// races `transcribe` against a wall-clock timer and returns nil if the timer wins, so one bad
    /// file can never hang the whole run. The inner task is cancelled best-effort (and abandoned
    /// if it ignores cancellation — harmless; ingest moves on).
    static func transcribeWithDeadline(_ url: URL, deadline: TimeInterval = 100) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let once = OnceResume()
            let work = Task { let r = await transcribe(url); once.fire { cont.resume(returning: r) } }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                work.cancel()
                once.fire { cont.resume(returning: nil) }
            }
        }
    }

    /// Resume a continuation exactly once, whichever of the racing tasks finishes first.
    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire(_ resume: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            resume()
        }
    }

    static func transcribe(_ url: URL, quietBail: TimeInterval = 15, maxTimeout: TimeInterval = 90) async -> String? {
        let status = await authorize()
        guard status == .authorized else { return nil }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { return nil }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true   // so we can keep best-so-far on timeout

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let holder = TaskHolder()
            holder.resume = { cont.resume(returning: $0) }
            holder.task = recognizer.recognitionTask(with: request) { result, error in
                if let result { holder.update(result.bestTranscription.formattedString) }
                if error != nil { holder.finishBest(); return }
                if let result, result.isFinal { holder.finishBest() }
            }
            // Quiet bail: nothing heard yet ⇒ probably music ⇒ skip fast.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(quietBail * 1_000_000_000))
                holder.bailIfQuiet()
            }
            // Hard cap: keep what we transcribed so far, then move on.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(maxTimeout * 1_000_000_000))
                holder.finishBest()
            }
        }
    }

    private static func authorize() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }

    /// Resumes the continuation exactly once — from the recognizer (final/error), the
    /// quiet-bail timer, or the hard cap — keeping the best partial transcript and
    /// cancelling the recognition task on the way out.
    private final class TaskHolder: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
        var resume: ((String?) -> Void)?
        private var best = ""
        private var done = false
        private let lock = NSLock()

        func update(_ s: String) {
            lock.lock(); if s.count > best.count { best = s }; lock.unlock()
        }
        /// Finish with the best transcript captured so far (nil if nothing usable).
        func finishBest() {
            lock.lock(); let b = best; lock.unlock()
            let trimmed = b.trimmingCharacters(in: .whitespacesAndNewlines)
            finish(trimmed.isEmpty ? nil : trimmed)
        }
        /// Skip the file if no speech has been heard yet (likely music).
        func bailIfQuiet() {
            lock.lock(); let empty = best.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty; lock.unlock()
            if empty { finish(nil) }
        }
        private func finish(_ value: String?) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            task?.cancel()
            resume?(value)
            resume = nil
        }
    }
}
