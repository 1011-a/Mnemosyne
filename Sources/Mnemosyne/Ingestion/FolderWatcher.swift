import Foundation
import CoreServices

/// Watches a set of folders with FSEvents and reports changed paths (debounced)
/// so the knowledge base can re-ingest automatically — no manual refresh.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "mnemosyne.folderwatcher")
    private let onChange: @Sendable ([String]) -> Void
    private let debounce: TimeInterval

    // Debounce state (touched only on `queue`).
    private var pending = Set<String>()
    private var flushWork: DispatchWorkItem?

    init(debounce: TimeInterval = 1.5, onChange: @escaping @Sendable ([String]) -> Void) {
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit { stop() }

    func start(paths: [URL]) {
        stop()
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, eventCallback, &ctx,
            paths.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce, flags) else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // Called on `queue` from the C callback.
    fileprivate func ingest(paths: [String]) {
        for p in paths { pending.insert(p) }
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = Array(self.pending)
            self.pending.removeAll()
            guard !batch.isEmpty else { return }
            self.onChange(batch)
        }
        flushWork = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}

// Top-level C callback — recovers the watcher from the context `info` pointer.
private func eventCallback(_ stream: ConstFSEventStreamRef,
                           _ info: UnsafeMutableRawPointer?,
                           _ count: Int,
                           _ paths: UnsafeMutableRawPointer,
                           _ flags: UnsafePointer<FSEventStreamEventFlags>,
                           _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
    let cfPaths = unsafeBitCast(paths, to: CFArray.self)
    let array = (cfPaths as? [String]) ?? []
    watcher.ingest(paths: array)
}
