import AppKit
import Observation

/// Lazily loads + caches small preview thumbnails for Library cards, so the grid
/// renders fast and never re-reads a file it's already previewed.
@MainActor
@Observable
final class ThumbnailStore {
    private var cache: [String: NSImage] = [:]
    private var inflight: Set<String> = []

    func cached(_ id: String) -> NSImage? { cache[id] }

    /// Load the thumbnail for `item` if it's a visual kind and not already cached.
    func load(_ item: KnowledgeItem) async {
        guard cache[item.id] == nil, !inflight.contains(item.id),
              item.kind == .image || item.kind == .pdf else { return }
        inflight.insert(item.id)
        let path = item.path, kind = item.kind
        let data = await Task.detached(priority: .utility) {
            PreviewLoader.previewPNG(for: URL(fileURLWithPath: path), kind: kind, maxDimension: 160)
        }.value
        inflight.remove(item.id)
        if let data, let image = NSImage(data: data) { cache[item.id] = image }
    }

    /// Drop a cached entry (e.g. after re-ingest).
    func invalidate(_ id: String) { cache[id] = nil }
}
