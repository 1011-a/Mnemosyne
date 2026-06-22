import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Runs an external CLI with a HARD timeout that reliably kills a hung or slow process.
/// The old per-client watchdog only sent SIGTERM — which a Node app (claude / codex) can
/// catch and ignore, leaving ingest stuck on one file forever. This escalates
/// SIGTERM → SIGKILL after a grace period, so a wedged subprocess is always reaped and
/// ingest moves on to the next file (or the next engine in the fallback order).
///
/// Returns the exit status + captured output + whether the timeout fired, so each caller
/// keeps its own interpretation (stdout vs. an output file, failure logging, etc.).
enum ProcessRunner {

    struct Result: Sendable {
        let status: Int32      // process exit status (-1 if it never spawned)
        let output: Data       // captured stdout (and stderr when merged)
        let timedOut: Bool     // true when the watchdog had to kill it
    }

    /// Thread-safe flag the watchdog sets and the caller reads after the run.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }

    static func run(bin: String, args: [String], timeout: TimeInterval,
                    cwd: String? = nil, env: [String: String]? = nil,
                    mergeStderr: Bool = false, graceSeconds: TimeInterval = 2) async -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { proc.environment = env }
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = mergeStderr ? outPipe : FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice        // avoid a CLI's stdin wait

        do { try proc.run() } catch { return Result(status: -1, output: Data(), timedOut: false) }
        let pid = proc.processIdentifier

        // Watchdog: SIGTERM, then SIGKILL if it's still alive after the grace period.
        // Killing the process closes its stdout write-end, which unblocks the read below.
        let timedOut = Flag()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if proc.isRunning {
                timedOut.set()
                proc.terminate()                                                   // SIGTERM
                try? await Task.sleep(nanoseconds: UInt64(graceSeconds * 1_000_000_000))
                if proc.isRunning { kill(pid, SIGKILL) }                           // force-reap
            }
        }

        let data: Data = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let d = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                cont.resume(returning: d)
            }
        }
        watchdog.cancel()
        return Result(status: proc.terminationStatus, output: data, timedOut: timedOut.value)
    }
}
