import SwiftUI
import Observation

enum LibrarySort: String, CaseIterable, Sendable {
    case recent = "Recent", name = "Name", size = "Size", cited = "Cited"
}

@MainActor
@Observable
final class LibraryViewModel {
    var items: [KnowledgeItem] = []
    var query: String = ""
    var loading = false
    var sort: LibrarySort = .recent
    /// Empty == all kinds. Otherwise only these kinds are shown.
    var activeKinds: Set<ItemKind> = []
    /// nil == all. Otherwise only items carrying this tag are shown.
    var activeTag: String?
    var tagsByItem: [String: [String]] = [:]
    var savedSearches: [SavedSearch] = []
    var citationCounts: [String: Int] = [:]
    /// Item ids whose chunk text matches the current query (full-text search).
    var contentMatchIDs: Set<String> = []
    // Multi-select for bulk actions.
    var selectionMode = false
    var selection: Set<String> = []
    private let store: KnowledgeStore

    init(store: KnowledgeStore) { self.store = store }

    /// Tags present in the corpus with counts, most-used first.
    var tagCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for tags in tagsByItem.values { for t in tags { counts[t, default: 0] += 1 } }
        return counts.map { (tag: $0.key, count: $0.value) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.tag < $1.tag) }
    }

    /// Kinds present in the corpus, with counts, ordered by frequency.
    var kindCounts: [(kind: ItemKind, count: Int)] {
        Dictionary(grouping: items, by: \.kind)
            .map { (kind: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    var filtered: [KnowledgeItem] {
        var result = items
        if !activeKinds.isEmpty { result = result.filter { activeKinds.contains($0.kind) } }
        if let tag = activeTag { result = result.filter { tagsByItem[$0.id]?.contains(tag) == true } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            result = result.filter {
                $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q)
                    || $0.path.lowercased().contains(q) || contentMatchIDs.contains($0.id)
            }
        }
        switch sort {
        case .recent: result.sort { $0.modifiedAt > $1.modifiedAt }
        case .name:   result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .size:   result.sort { $0.byteSize > $1.byteSize }
        case .cited:  result.sort { (citationCounts[$0.id] ?? 0) > (citationCounts[$1.id] ?? 0) }
        }
        return result
    }

    func toggleKind(_ kind: ItemKind) {
        if activeKinds.contains(kind) { activeKinds.remove(kind) } else { activeKinds.insert(kind) }
    }

    // MARK: Multi-select & bulk tagging

    func toggleSelectionMode() {
        selectionMode.toggle()
        if !selectionMode { selection.removeAll() }
    }
    func toggleSelected(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    func selectAllFiltered() { selection = Set(filtered.map(\.id)) }
    func clearSelection() { selection.removeAll() }

    /// Titles of the selected items, oldest first — so a diff reads old → new.
    func selectedTitlesOldestFirst() -> [String] {
        items.filter { selection.contains($0.id) }
            .sorted { $0.modifiedAt < $1.modifiedAt }
            .map(\.title)
    }

    /// Reset search text, kind chips, and the active tag (Esc in Library).
    func clearFilters() {
        query = ""
        activeKinds = []
        activeTag = nil
        contentMatchIDs = []
    }

    func addTagToSelection(_ raw: String) { applyTagToSelection(raw, add: true) }
    func removeTagFromSelection(_ raw: String) { applyTagToSelection(raw, add: false) }

    func deleteSelection() {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        for id in ids { tagsByItem[id] = nil; citationCounts[id] = nil }
        selection.removeAll()
        Task { try? await store.deleteItems(ids: ids) }
    }

    func renameTag(from: String, to: String) {
        Task {
            try? await store.renameTag(from: from, to: to)
            let refreshed = (try? await store.tagsByItem()) ?? [:]
            self.tagsByItem = refreshed
            let normTo = to.trimmingCharacters(in: .whitespaces).lowercased()
            if activeTag == from.trimmingCharacters(in: .whitespaces).lowercased() {
                activeTag = normTo.isEmpty ? nil : normTo
            }
        }
    }

    /// Near-duplicate label clusters (format/case/plural twins) the user can merge.
    var nearDuplicateTagClusters: [[String]] {
        TagCleanup.nearDuplicateClusters(tagCounts.map { ($0.tag, $0.count) })
    }

    /// How many loaded items carry no labels (drives the "Auto-label" affordance).
    var untaggedCount: Int {
        items.filter { (tagsByItem[$0.id] ?? []).isEmpty }.count
    }

    /// Sets of files with identical content (drives the "duplicates" banner).
    var duplicateSets: [[String]] {
        ToolAgent.duplicateGroups(items.map { (title: $0.title, hash: $0.contentHash) })
    }

    /// Duplicate groups as full items (for the dedupe view), largest set first.
    var duplicateItemGroups: [[KnowledgeItem]] {
        var byHash: [String: [KnowledgeItem]] = [:]
        for it in items where !it.contentHash.isEmpty { byHash[it.contentHash, default: []].append(it) }
        return byHash.values.filter { $0.count >= 2 }
            .map { $0.sorted { $0.title < $1.title } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : ($0.first?.title ?? "") < ($1.first?.title ?? "") }
    }

    /// Remove ONE item from the knowledge base (the file on disk is untouched).
    func deleteItem(_ id: String) {
        items.removeAll { $0.id == id }
        tagsByItem[id] = nil; citationCounts[id] = nil
        Task { try? await store.deleteItems(ids: [id]) }
    }

    /// Labels that co-occur with `tag` on the same items, strongest first — shown as
    /// "related" chips when filtering by a tag, for exploration. Reuses TagStats.
    func relatedTags(to tag: String, limit: Int = 6) -> [String] {
        let t = tag.lowercased()
        var out: [String] = []
        for pair in TagStats.coOccurrences(Array(tagsByItem.values), top: 100) {
            if pair.a.lowercased() == t { out.append(pair.b) }
            else if pair.b.lowercased() == t { out.append(pair.a) }
            if out.count == limit { break }
        }
        return out
    }

    /// Merge a near-duplicate cluster into its first (most-used) label across the
    /// whole library, then refresh. Reuses the agent's pure merge logic.
    func mergeCluster(_ labels: [String]) {
        guard let target = labels.first, labels.count >= 2 else { return }
        let sources = Set(labels)
        Task {
            let byItem = (try? await store.tagsByItem()) ?? [:]
            for (id, tags) in byItem {
                if let newTags = ToolAgent.mergedTags(tags, from: sources, into: target) {
                    try? await store.setTags(newTags, forItem: id)
                }
            }
            self.tagsByItem = (try? await store.tagsByItem()) ?? [:]
            let normTarget = target.trimmingCharacters(in: .whitespaces).lowercased()
            if let active = activeTag, sources.map({ $0.lowercased() }).contains(active) {
                activeTag = normTarget
            }
        }
    }

    private func applyTagToSelection(_ raw: String, add: Bool) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tag.isEmpty, !selection.isEmpty else { return }
        var updates: [String: [String]] = [:]
        for id in selection {
            var tags = Set(tagsByItem[id] ?? [])
            if add { tags.insert(tag) } else { tags.remove(tag) }
            let arr = tags.sorted()
            tagsByItem[id] = arr
            updates[id] = arr
        }
        Task { for (id, tags) in updates { try? await store.setTags(tags, forItem: id) } }
    }

    // MARK: Saved searches

    var hasActiveFilter: Bool {
        !activeKinds.isEmpty || activeTag != nil || !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func saveCurrentFilter() {
        let kinds = Array(activeKinds)
        let search = SavedSearch(
            name: SavedSearch.defaultName(query: query, kinds: kinds, tag: activeTag),
            query: query, kinds: kinds, tag: activeTag)
        Task {
            try? await store.saveSearch(search)
            loadSavedSearches()
        }
    }

    func apply(_ search: SavedSearch) {
        query = search.query
        activeKinds = Set(search.kinds)
        activeTag = search.tag
    }

    func deleteSearch(_ search: SavedSearch) {
        Task { try? await store.deleteSavedSearch(id: search.id); loadSavedSearches() }
    }

    func loadSavedSearches() {
        Task { savedSearches = (try? await store.allSavedSearches()) ?? [] }
    }

    struct ManifestEntry: Codable, Sendable {
        let title: String, kind: String, path: String
        let bytes: Int64, modified: Date
    }

    /// Export the currently-filtered items as a pretty JSON manifest.
    func exportManifestJSON() throws -> String {
        let entries = filtered.map {
            ManifestEntry(title: $0.title, kind: $0.kind.rawValue, path: $0.path,
                          bytes: $0.byteSize, modified: $0.modifiedAt)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return String(decoding: try enc.encode(entries), as: UTF8.self)
    }

    /// Full-text search across chunk content for the current query.
    func runContentSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { contentMatchIDs = []; return }
        Task { contentMatchIDs = (try? await store.itemIDsMatchingContent(q)) ?? [] }
    }

    func reload() {
        loading = true
        Task { [store] in
            let loaded = (try? await store.allItems()) ?? []
            let tags = (try? await store.tagsByItem()) ?? [:]
            let searches = (try? await store.allSavedSearches()) ?? []
            let cites = (try? await store.citationCounts()) ?? [:]
            self.items = loaded
            self.tagsByItem = tags
            self.savedSearches = searches
            self.citationCounts = cites
            self.loading = false
        }
    }
}

/// Browsable grid of everything ingested.
struct LibraryView: View {
    @Bindable var vm: LibraryViewModel
    let store: KnowledgeStore
    var onAsk: (KnowledgeItem) -> Void
    /// Jump to Ask and run a free-text query (e.g. a diff of two selected files).
    var onAskText: (String) -> Void = { _ in }
    var onIngest: () -> Void = {}
    var onReingest: (String) -> Void = { _ in }
    var focusToken: Int = 0
    @State private var selected: KnowledgeItem?
    @State private var thumbs = ThumbnailStore()
    @State private var mapMode = false
    @State private var dismissedCleanup = false
    @State private var dismissedAutoLabel = false
    @State private var dismissedDuplicates = false
    @State private var showDuplicates = false
    @FocusState private var searchFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: DS.Space.x4)]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x5) {
            header
            if !vm.items.isEmpty { filterBar }
            if !vm.tagCounts.isEmpty { tagBar }
            if let active = vm.activeTag {
                let related = vm.relatedTags(to: active)
                if !related.isEmpty { relatedTagsBar(active: active, related: related) }
            }
            if !dismissedCleanup, !vm.nearDuplicateTagClusters.isEmpty { tagCleanupCard }
            if !dismissedAutoLabel, vm.untaggedCount >= 3 { autoLabelBanner }
            if !dismissedDuplicates, !vm.duplicateSets.isEmpty { duplicatesBanner }
            if !vm.savedSearches.isEmpty || vm.hasActiveFilter { savedBar }
            if vm.selectionMode { selectionBar }
            if vm.items.isEmpty {
                empty
            } else if mapMode {
                ScrollView {
                    KnowledgeMapView(items: vm.filtered, tagsByItem: vm.tagsByItem,
                                     citationCounts: vm.citationCounts) { selected = $0 }
                        .padding(.bottom, DS.Space.x8)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: DS.Space.x4) {
                        ForEach(vm.filtered) { item in
                            Button {
                                if vm.selectionMode { vm.toggleSelected(item.id) } else { selected = item }
                            } label: {
                                KnowledgeCard(icon: item.kind.sfSymbol,
                                              kindLabel: item.kind.rawValue,
                                              title: item.title,
                                              summary: item.summary.isEmpty ? item.path : item.summary,
                                              meta: "\(Format.bytes(item.byteSize)) · \(Format.ago(item.modifiedAt))",
                                              citedCount: vm.citationCounts[item.id] ?? 0,
                                              thumbnail: thumbs.cached(item.id))
                                .overlay(alignment: .topTrailing) {
                                    if vm.selectionMode { selectionMark(vm.selection.contains(item.id)) }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("library.card")
                            .task(id: item.id) { await thumbs.load(item) }
                        }
                    }
                    .padding(.bottom, DS.Space.x8)
                }
            }
        }
        .padding(DS.Space.x8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .onAppear { if vm.items.isEmpty { vm.reload() } }
        // ⌘F focuses the search field (token bumped by AppShell); a small delay
        // lets the field render after a section switch before focusing.
        .task(id: focusToken) {
            guard focusToken > 0 else { return }
            // After a section switch the view + window-key state take a few frames
            // to settle; set focus after a delay and once more so it reliably lands.
            for ms in [200, 450] as [UInt64] {
                try? await Task.sleep(nanoseconds: ms * 1_000_000)
                searchFocused = true
            }
        }
        // Esc clears search + filters.
        .onExitCommand { vm.clearFilters(); searchFocused = false }
        .sheet(item: $selected) { item in
            ItemDetailView(item: item, store: store, onAsk: onAsk, onAskText: onAskText, onReingest: onReingest)
        }
        .sheet(isPresented: $showDuplicates) { DuplicatesView(vm: vm) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            SectionHeader("Library", subtitle: "\(vm.filtered.count) of \(vm.items.count) items")
            Spacer()
            searchBox
            sortMenu
            DSButton(mapMode ? "Grid" : "Map",
                     icon: mapMode ? "square.grid.2x2" : "point.3.filled.connected.trianglepath.dotted",
                     kind: .secondary) { withAnimation(DS.Motion.base) { mapMode.toggle() } }
                .accessibilityIdentifier("library.mapToggle")
            DSButton(vm.selectionMode ? "Done" : "Select",
                     icon: vm.selectionMode ? "checkmark.circle" : "checkmark.circle.badge.questionmark",
                     kind: .secondary) { vm.toggleSelectionMode() }
            DSButton("Export", icon: "square.and.arrow.up", kind: .secondary) {
                if let json = try? vm.exportManifestJSON() {
                    SavePanel.writeText(json, suggestedName: "mnemosyne-library.json", types: [.json])
                }
            }
            DSButton("Refresh", icon: "arrow.clockwise", kind: .secondary) { vm.reload() }
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases, id: \.self) { option in
                Button { vm.sort = option } label: {
                    HStack {
                        Text(option.rawValue)
                        if vm.sort == option { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: DS.Space.x2) {
                Image(systemName: "arrow.up.arrow.down")
                Text(vm.sort.rawValue)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.textTertiary)
            }
            .font(DS.Typo.bodyMed)
            .foregroundStyle(DS.ColorToken.textPrimary)
            .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x3)
            .background(DS.ColorToken.surfaceOverlay)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
            .dsShadow(DS.Elevation.e1)
        }
        // Neutral tint so the trigger matches the other toolbar buttons; the
        // global vermilion would otherwise color these template glyphs.
        // `.button` (not `.borderlessButton`) honours the label's own background.
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .tint(DS.ColorToken.textPrimary)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.x2) {
                kindChip(label: "All", icon: "square.stack.3d.up", count: vm.items.count,
                         active: vm.activeKinds.isEmpty) { vm.activeKinds.removeAll() }
                ForEach(vm.kindCounts, id: \.kind) { entry in
                    kindChip(label: entry.kind.rawValue, icon: entry.kind.sfSymbol, count: entry.count,
                             active: vm.activeKinds.contains(entry.kind)) { vm.toggleKind(entry.kind) }
                }
            }
        }
    }

    private var tagBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.x2) {
                ForEach(vm.tagCounts, id: \.tag) { entry in
                    let active = vm.activeTag == entry.tag
                    Button { vm.activeTag = active ? nil : entry.tag } label: {
                        HStack(spacing: DS.Space.x1) {
                            Image(systemName: "tag.fill").font(.system(size: 9))
                            Text(entry.tag).font(DS.Typo.caption)
                            Text("\(entry.count)").font(DS.Typo.caption)
                                .foregroundStyle(active ? .white.opacity(0.8) : DS.ColorToken.textTertiary)
                        }
                        .foregroundStyle(active ? Color.white : DS.ColorToken.provenance)
                        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                        .background {
                            if active { Capsule().fill(DS.ColorToken.provenance) }
                            else { Capsule().fill(DS.ColorToken.provenance.opacity(0.12)) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename tag…") { renamingTag = entry.tag; renameText = entry.tag }
                    }
                }
            }
        }
        .alert("Rename tag", isPresented: Binding(get: { renamingTag != nil },
                                                  set: { if !$0 { renamingTag = nil } })) {
            TextField("New name", text: $renameText)
            Button("Rename") {
                if let from = renamingTag { vm.renameTag(from: from, to: renameText) }
                renamingTag = nil
            }
            Button("Cancel", role: .cancel) { renamingTag = nil }
        } message: {
            Text("Renames this tag across all items (merges if the new name exists).")
        }
    }

    @State private var bulkTag: String = ""
    @State private var confirmingDelete = false
    @State private var renamingTag: String?
    @State private var renameText: String = ""

    /// Nudge to batch-label the inbox when several files are unlabelled. Routes to
    /// the agent's auto_label_untagged (which previews before applying).
    private var autoLabelBanner: some View {
        HStack(spacing: DS.Space.x3) {
            Image(systemName: "wand.and.stars").font(.system(size: 11)).foregroundStyle(DS.ColorToken.iris)
            Text("\(vm.untaggedCount) files have no labels").font(DS.Typo.callout)
                .foregroundStyle(DS.ColorToken.textSecondary)
            Spacer(minLength: DS.Space.x3)
            Button {
                onAskText("Auto-label my untagged files using auto_label_untagged — preview the proposed labels first, then ask me before applying.")
            } label: {
                Text("Auto-label").font(DS.Typo.caption).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                    .background(DS.ColorToken.iris, in: Capsule())
            }.buttonStyle(.plain)
            Button { withAnimation(DS.Motion.snappy) { dismissedAutoLabel = true } } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(DS.ColorToken.textTertiary)
            }.buttonStyle(.plain).help("Dismiss")
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.iris.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.iris.opacity(0.25)))
    }

    /// Surface exact-duplicate files so the user can review/clean them via the agent.
    private var duplicatesBanner: some View {
        let sets = vm.duplicateSets
        let dupeFiles = sets.reduce(0) { $0 + $1.count }
        return HStack(spacing: DS.Space.x3) {
            Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(DS.ColorToken.iris)
            Text("\(sets.count) set\(sets.count == 1 ? "" : "s") of identical files (\(dupeFiles) files)")
                .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
            Spacer(minLength: DS.Space.x3)
            Button { showDuplicates = true } label: {
                Text("Review").font(DS.Typo.caption).foregroundStyle(.white)
                    .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                    .background(DS.ColorToken.iris, in: Capsule())
            }.buttonStyle(.plain)
            Button { withAnimation(DS.Motion.snappy) { dismissedDuplicates = true } } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(DS.ColorToken.textTertiary)
            }.buttonStyle(.plain).help("Dismiss")
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.iris.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.iris.opacity(0.25)))
    }

    /// When filtering by a tag, show the labels that most often appear alongside it —
    /// tap one to pivot the filter to that related topic.
    private func relatedTagsBar(active: String, related: [String]) -> some View {
        HStack(spacing: DS.Space.x2) {
            Text("RELATED TO \(active.uppercased())").font(DS.Typo.caption).tracking(1)
                .foregroundStyle(DS.ColorToken.textTertiary).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.x2) {
                    ForEach(related, id: \.self) { tag in
                        Button { withAnimation(DS.Motion.snappy) { vm.activeTag = tag } } label: {
                            HStack(spacing: DS.Space.x1) {
                                Image(systemName: "link").font(.system(size: 8))
                                Text(tag).font(DS.Typo.caption)
                            }
                            .foregroundStyle(DS.ColorToken.provenance)
                            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                            .overlay(Capsule().strokeBorder(DS.ColorToken.provenance.opacity(0.35), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Proactive tidy-up: when near-duplicate labels exist, offer a one-tap merge
    /// per cluster (into the most-used variant). Reuses the agent's merge logic.
    private var tagCleanupCard: some View {
        let clusters = vm.nearDuplicateTagClusters.prefix(4)
        return VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                Image(systemName: "wand.and.stars").font(.system(size: 11)).foregroundStyle(DS.ColorToken.iris)
                Text("TIDY UP LABELS").font(DS.Typo.caption).tracking(1).foregroundStyle(DS.ColorToken.textSecondary)
                Spacer()
                Button { withAnimation(DS.Motion.snappy) { dismissedCleanup = true } } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(DS.ColorToken.textTertiary)
                }.buttonStyle(.plain).help("Dismiss")
            }
            ForEach(Array(clusters), id: \.self) { cluster in
                HStack(spacing: DS.Space.x2) {
                    Text(cluster.joined(separator: "  ·  "))
                        .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.x3)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(DS.ColorToken.textTertiary)
                    Button { withAnimation(DS.Motion.snappy) { vm.mergeCluster(cluster) } } label: {
                        Text("Merge → \(cluster.first ?? "")").font(DS.Typo.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                            .background(DS.ColorToken.iris, in: Capsule())
                    }.buttonStyle(.plain).help("Merge these labels into '\(cluster.first ?? "")' everywhere")
                }
            }
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.ColorToken.iris.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.iris.opacity(0.25)))
    }

    private func selectionMark(_ on: Bool) -> some View {
        Image(systemName: on ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 18))
            .foregroundStyle(on ? DS.ColorToken.iris : DS.ColorToken.textTertiary)
            .background(Circle().fill(DS.ColorToken.canvas).padding(2))
            .padding(DS.Space.x2)
    }

    private var selectionBar: some View {
        HStack(spacing: DS.Space.x3) {
            Text("\(vm.selection.count) selected").font(DS.Typo.bodyMed)
                .foregroundStyle(DS.ColorToken.textPrimary)
            Button("Select all") { vm.selectAllFiltered() }.buttonStyle(.plain)
                .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.iris)
            Button("Clear") { vm.clearSelection() }.buttonStyle(.plain)
                .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
            Spacer()
            HStack(spacing: DS.Space.x2) {
                Image(systemName: "tag").foregroundStyle(DS.ColorToken.textTertiary)
                TextField("tag…", text: $bulkTag)
                    .textFieldStyle(.plain).font(DS.Typo.callout).frame(width: 120)
                    .foregroundStyle(DS.ColorToken.textPrimary)
                    .onSubmit { vm.addTagToSelection(bulkTag); bulkTag = "" }
            }
            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
            .background(DS.ColorToken.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.md))
            DSButton("Add tag", icon: "plus", kind: .primary) {
                vm.addTagToSelection(bulkTag); bulkTag = ""
            }
            DSButton("Remove", icon: "minus", kind: .secondary) {
                vm.removeTagFromSelection(bulkTag); bulkTag = ""
            }
            // Exactly two selected → offer a line-level diff via the agent.
            if vm.selection.count == 2 {
                DSButton("Diff", icon: "plus.forwardslash.minus", kind: .secondary) {
                    let t = vm.selectedTitlesOldestFirst()
                    if t.count == 2 {
                        onAskText("What changed between \u{201C}\(t[0])\u{201D} and \u{201C}\(t[1])\u{201D}? Use diff_items to show the line-level changes.")
                    }
                }
            }
            DSButton("Delete", icon: "trash", kind: .ghost) { confirmingDelete = true }
                .confirmationDialog("Remove \(vm.selection.count) item(s) from your knowledge base?",
                                    isPresented: $confirmingDelete, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { vm.deleteSelection() }
                    Button("Cancel", role: .cancel) {}
                }
        }
        .padding(DS.Space.x3)
        .background(DS.ColorToken.surface, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
        .disabled(vm.selection.isEmpty)
        .opacity(vm.selection.isEmpty ? 0.6 : 1)
    }

    @State private var hoveredSearch: String?
    private var savedBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.x2) {
                if vm.hasActiveFilter {
                    Button { vm.saveCurrentFilter() } label: {
                        HStack(spacing: DS.Space.x1) {
                            Image(systemName: "plus").font(.system(size: 9))
                            Text("Save filter").font(DS.Typo.caption)
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                        .background(DS.Gradient.intelligence, in: Capsule())
                    }.buttonStyle(.plain)
                }
                ForEach(vm.savedSearches) { search in
                    Button { vm.apply(search) } label: {
                        HStack(spacing: DS.Space.x1) {
                            Image(systemName: "bookmark.fill").font(.system(size: 9))
                            Text(search.name).font(DS.Typo.caption).lineLimit(1)
                            if hoveredSearch == search.id {
                                Button { vm.deleteSearch(search) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8))
                                }.buttonStyle(.plain)
                            }
                        }
                        .foregroundStyle(DS.ColorToken.textSecondary)
                        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x1)
                        .background(Capsule().fill(DS.ColorToken.surfaceRaised)
                            .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1)))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredSearch = $0 ? search.id : (hoveredSearch == search.id ? nil : hoveredSearch) }
                }
            }
        }
    }

    private func kindChip(label: String, icon: String, count: Int, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: DS.Space.x2) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(DS.Typo.caption)
                Text("\(count)").font(DS.Typo.caption).foregroundStyle(active ? .white.opacity(0.8) : DS.ColorToken.textTertiary)
            }
            .foregroundStyle(active ? Color.white : DS.ColorToken.textSecondary)
            .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
            .background {
                if active {
                    Capsule().fill(DS.Gradient.intelligence)
                } else {
                    Capsule().fill(DS.ColorToken.surfaceRaised)
                        .overlay(Capsule().strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var searchBox: some View {
        HStack(spacing: DS.Space.x2) {
            Image(systemName: "magnifyingglass").foregroundStyle(DS.ColorToken.textTertiary)
            TextField("Search title & content…", text: $vm.query)
                .textFieldStyle(.plain).font(DS.Typo.body)
                .foregroundStyle(DS.ColorToken.textPrimary)
                .frame(width: 180)
                .focused($searchFocused)
                .onChange(of: vm.query) { _, _ in vm.runContentSearch() }
        }
        .padding(.horizontal, DS.Space.x3).padding(.vertical, DS.Space.x2)
        .background(DS.ColorToken.surfaceRaised, in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(DS.ColorToken.borderDefault, lineWidth: 1))
    }

    private var empty: some View {
        VStack(spacing: DS.Space.x3) {
            Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(DS.ColorToken.textTertiary)
            Text("Nothing ingested yet").font(DS.Typo.title3).foregroundStyle(DS.ColorToken.textSecondary)
            Text("Point Mnemosyne at a folder and it will absorb everything inside.")
                .font(DS.Typo.callout).foregroundStyle(DS.ColorToken.textTertiary)
            DSButton("Ingest your first folder", icon: "tray.and.arrow.down", kind: .primary, action: onIngest)
                .padding(.top, DS.Space.x2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
