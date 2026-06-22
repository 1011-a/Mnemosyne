import Foundation
import Observation

/// Observable, main-actor ingestion state for the UI (dashboard + status pill).
///
/// Progress is tracked with a **job counter** rather than a single begin/finish
/// pair. Several ingest operations can be in flight at once — the initial folder
/// scan, plus small FSEvents batches the folder-watcher fires *while that scan is
/// still running*. Counting active jobs means their files accumulate into ONE
/// coherent total, and the run only reads "Up to date" once EVERY job has
/// finished — not when the first stray 3-file watcher batch happens to complete.
/// One line in the live activity console.
struct IngestLogLine: Identifiable, Sendable {
    enum Level: Sendable { case work, added, skip, warn }
    let id: Int
    let symbol: String
    let text: String
    let level: Level
}

@MainActor
@Observable
final class IngestProgress {
    enum Phase: Equatable { case idle, scanning, ingesting, done, failed(String) }

    var phase: Phase = .idle
    var total: Int = 0
    var processed: Int = 0
    var skipped: Int = 0
    var added: Int = 0
    /// Total items currently in the knowledge base — a PERSISTED figure read from
    /// the store, so reopening the app still shows how much is indexed (the
    /// per-run `added`/`skipped` counters reset each launch; this does not).
    var libraryItems: Int = 0
    /// The file currently being worked on.
    var currentFile: String = ""
    /// What's happening to `currentFile` right now ("Looking at image — Gemma…",
    /// "Embedding 200/1200", "Unchanged"). Lets the UI explain why a slow file sits.
    var activity: String = ""
    var recentlyAdded: [String] = []

    /// Rolling live-activity console (bounded ring buffer of the most recent lines).
    var log: [IngestLogLine] = []
    private var logSeq = 0

    /// Number of ingest operations currently in flight. The run is "done" only
    /// when this returns to zero.
    private var activeJobs = 0

    func appendLog(_ symbol: String, _ text: String, _ level: IngestLogLine.Level) {
        logSeq += 1
        log.append(IngestLogLine(id: logSeq, symbol: symbol, text: text, level: level))
        if log.count > 160 { log.removeFirst(log.count - 160) }
    }

    var fraction: Double { total == 0 ? 0 : min(1, Double(processed) / Double(total)) }
    var isRunning: Bool { phase == .scanning || phase == .ingesting }
    var remaining: Int { max(0, total - processed) }

    /// Mark that we're walking the filesystem (no per-file total known yet).
    func scanning() { if activeJobs == 0 { phase = .scanning } }

    /// Begin one ingest operation contributing `count` files. The first job of a
    /// fresh run zeroes the counters; later overlapping jobs simply add to the
    /// running total so the percentage stays monotonic and the count keeps rising.
    func beginJob(total count: Int) {
        if activeJobs == 0 && phase != .ingesting {
            processed = 0; skipped = 0; added = 0; total = 0
            currentFile = ""; activity = ""; recentlyAdded = []
        }
        activeJobs += 1
        total += count
        phase = .ingesting
    }

    /// End one ingest operation. "Up to date" shows only once the last one ends.
    func endJob() {
        activeJobs = max(0, activeJobs - 1)
        if activeJobs == 0 {
            phase = .done; currentFile = ""; activity = ""
        }
    }

    /// Report mid-work activity on a file (slow steps like Gemma / OCR / embedding)
    /// so the UI shows live movement instead of a frozen filename. Logs one console
    /// line each time a NEW file starts (so a slow step like audio transcription shows
    /// the file it's on — proof it's working, not stuck), but stays quiet for the many
    /// in-file updates (embedding 200/1200 …) so the console stays readable.
    func note(_ file: String, _ what: String) {
        if !file.isEmpty, file != currentFile {
            appendLog("▸", "\(what)  \(file)", .work)
        }
        currentFile = file; activity = what
    }

    func tickAdded(_ title: String) {
        processed += 1; added += 1; currentFile = title; activity = "Indexed"
        recentlyAdded.insert(title, at: 0)
        if recentlyAdded.count > 8 { recentlyAdded.removeLast() }
        appendLog("✓", "indexed  \(title)", .added)
    }
    func tickSkipped(_ title: String) {
        processed += 1; skipped += 1; currentFile = title; activity = "Unchanged"
        // Unchanged files fly by fast — log a heartbeat, not every one, to stay readable.
        if skipped % 20 == 0 { appendLog("·", "skipped \(skipped) unchanged…", .skip) }
    }
    func fail(_ message: String) { phase = .failed(message); activeJobs = 0 }
}
