import Foundation
import SQLite3
import NaturalLanguage

/// SQLite-backed persistence for the knowledge base. An `actor` so the raw
/// `sqlite3` handle is never touched concurrently. Embeddings are stored as
/// Float32 BLOBs and ranked in-memory by cosine similarity — simple and plenty
/// fast for a personal corpus; swap in a vector index if it ever outgrows RAM.
actor KnowledgeStore {
    // Accessed only on the actor at runtime; `nonisolated(unsafe)` solely so
    // `deinit` (which runs after the last reference is gone) can close it.
    private nonisolated(unsafe) var db: OpaquePointer?
    let dbURL: URL

    // SQLite asks us to copy bound text/blob immediately.
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directory: URL? = nil) throws {
        let dir = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mnemosyne", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.dbURL = dir.appendingPathComponent("knowledge.sqlite3")

        var handle: OpaquePointer?
        guard sqlite3_open(dbURL.path, &handle) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(handle)))
        }
        try Self.execRaw(handle, "PRAGMA journal_mode=WAL;")
        try Self.execRaw(handle, "PRAGMA synchronous=NORMAL;")
        try Self.execRaw(handle, "PRAGMA foreign_keys=ON;")
        try Self.migrate(handle)
        self.db = handle
    }

    deinit { if db != nil { sqlite3_close(db) } }

    private static func migrate(_ db: OpaquePointer?) throws {
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY, path TEXT NOT NULL, title TEXT NOT NULL,
            kind TEXT NOT NULL, content_hash TEXT NOT NULL, byte_size INTEGER NOT NULL,
            created_at REAL NOT NULL, modified_at REAL NOT NULL, summary TEXT NOT NULL DEFAULT ''
        );
        """)
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_items_path ON items(path);")
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY, item_id TEXT NOT NULL, ord INTEGER NOT NULL,
            text TEXT NOT NULL, embedding BLOB NOT NULL,
            FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        );
        """)
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_chunks_item ON chunks(item_id);")
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS threads (
            id TEXT PRIMARY KEY, title TEXT NOT NULL,
            created_at REAL NOT NULL, updated_at REAL NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0
        );
        """)
        // Add `pinned` to pre-existing DBs (no-op / ignored error if already present).
        try? execRaw(db, "ALTER TABLE threads ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;")
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, ord INTEGER NOT NULL,
            role TEXT NOT NULL, content TEXT NOT NULL, citations_json TEXT NOT NULL DEFAULT '[]',
            model TEXT NOT NULL DEFAULT '',
            FOREIGN KEY(thread_id) REFERENCES threads(id) ON DELETE CASCADE
        );
        """)
        try? execRaw(db, "ALTER TABLE messages ADD COLUMN model TEXT NOT NULL DEFAULT '';")
        try? execRaw(db, "ALTER TABLE messages ADD COLUMN reasoning TEXT NOT NULL DEFAULT '';")
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_messages_thread ON messages(thread_id);")
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS item_tags (
            item_id TEXT NOT NULL, tag TEXT NOT NULL,
            PRIMARY KEY(item_id, tag),
            FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        );
        """)
        try execRaw(db, "CREATE INDEX IF NOT EXISTS idx_item_tags_tag ON item_tags(tag);")
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS item_citations (
            item_id TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(item_id) REFERENCES items(id) ON DELETE CASCADE
        );
        """)
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS saved_searches (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL,
            kinds TEXT NOT NULL, tag TEXT, created_at REAL NOT NULL
        );
        """)
        // Incremental conversation-compaction summaries: one row per thread covering
        // messages[0..<boundary], so long threads don't re-summarize from scratch.
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS thread_summaries (
            thread_id TEXT PRIMARY KEY, boundary INTEGER NOT NULL, summary TEXT NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY(thread_id) REFERENCES threads(id) ON DELETE CASCADE
        );
        """)
        // Long-term memory: facts the user pins so the agent ALWAYS recalls them
        // across every conversation (injected into context, never compacted).
        try execRaw(db, """
        CREATE TABLE IF NOT EXISTS pinned_facts (
            id TEXT PRIMARY KEY, fact TEXT NOT NULL, created_at REAL NOT NULL
        );
        """)
    }

    // MARK: Saved searches (smart folders)

    func saveSearch(_ s: SavedSearch) throws {
        try run("INSERT OR REPLACE INTO saved_searches (id,name,query,kinds,tag,created_at) VALUES (?,?,?,?,?,?);") { st in
            bindText(st, 1, s.id); bindText(st, 2, s.name); bindText(st, 3, s.query)
            bindText(st, 4, s.kindsField)
            if let tag = s.tag { bindText(st, 5, tag) } else { sqlite3_bind_null(st, 5) }
            sqlite3_bind_double(st, 6, s.createdAt.timeIntervalSince1970)
            try step(st)
        }
    }

    func allSavedSearches() throws -> [SavedSearch] {
        var out: [SavedSearch] = []
        try run("SELECT id,name,query,kinds,tag,created_at FROM saved_searches ORDER BY created_at ASC;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                let tag = sqlite3_column_type(st, 4) == SQLITE_NULL ? nil
                    : sqlite3_column_text(st, 4).map { String(cString: $0) }
                out.append(SavedSearch(
                    id: Self.col(st, 0), name: Self.col(st, 1), query: Self.col(st, 2),
                    kinds: SavedSearch.parseKinds(Self.col(st, 3)), tag: tag,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 5))))
            }
        }
        return out
    }

    func deleteSavedSearch(id: String) throws {
        try run("DELETE FROM saved_searches WHERE id = ?;") { st in bindText(st, 1, id); try step(st) }
    }

    // MARK: Citation usage tracking

    /// Increment the cited-count for each item referenced in an answer.
    func recordCitations(itemIDs: [String]) throws {
        let ids = itemIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        try exec("BEGIN;")
        do {
            for id in ids {
                try run("""
                INSERT INTO item_citations (item_id, count) VALUES (?, 1)
                ON CONFLICT(item_id) DO UPDATE SET count = count + 1;
                """) { st in bindText(st, 1, id); try step(st) }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }

    /// Map of item id → how many times it's been cited (drives Library badges).
    func citationCounts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        try run("SELECT item_id, count FROM item_citations;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                let id = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
                if !id.isEmpty { out[id] = Int(sqlite3_column_int(st, 1)) }
            }
        }
        return out
    }

    /// Most-referenced items (joined to surviving items), highest first.
    func mostCited(limit: Int = 5) throws -> [(item: KnowledgeItem, count: Int)] {
        let items = try allItems()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var out: [(KnowledgeItem, Int)] = []
        try run("SELECT item_id, count FROM item_citations ORDER BY count DESC LIMIT ?;") { st in
            sqlite3_bind_int(st, 1, Int32(limit))
            while sqlite3_step(st) == SQLITE_ROW {
                let id = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
                if let item = byID[id] { out.append((item, Int(sqlite3_column_int(st, 1)))) }
            }
        }
        return out
    }

    // MARK: Tags

    private static func normalizeTag(_ t: String) -> String {
        t.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Replace all tags for an item (normalized, de-duplicated).
    func setTags(_ tags: [String], forItem itemID: String) throws {
        let clean = Set(tags.map(Self.normalizeTag).filter { !$0.isEmpty })
        try exec("BEGIN;")
        do {
            try run("DELETE FROM item_tags WHERE item_id = ?;") { st in bindText(st, 1, itemID); try step(st) }
            for tag in clean.sorted() {
                try run("INSERT INTO item_tags (item_id, tag) VALUES (?, ?);") { st in
                    bindText(st, 1, itemID); bindText(st, 2, tag); try step(st)
                }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }

    /// Rename a tag across all items, merging into `to` (items having both keep
    /// only `to`, avoiding a primary-key clash).
    func renameTag(from rawFrom: String, to rawTo: String) throws {
        let from = Self.normalizeTag(rawFrom), to = Self.normalizeTag(rawTo)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        try exec("BEGIN;")
        do {
            // Drop `from` where the item already has `to` (merge case).
            try run("DELETE FROM item_tags WHERE tag = ? AND item_id IN (SELECT item_id FROM item_tags WHERE tag = ?);") { st in
                bindText(st, 1, from); bindText(st, 2, to); try step(st)
            }
            // Rename the remaining `from` rows to `to`.
            try run("UPDATE item_tags SET tag = ? WHERE tag = ?;") { st in
                bindText(st, 1, to); bindText(st, 2, from); try step(st)
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }

    func tags(forItem itemID: String) throws -> [String] {
        var out: [String] = []
        try run("SELECT tag FROM item_tags WHERE item_id = ? ORDER BY tag;") { st in
            bindText(st, 1, itemID)
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 0) { out.append(String(cString: c)) }
            }
        }
        return out
    }

    /// All tags with their usage counts, most-used first.
    func allTags() throws -> [(tag: String, count: Int)] {
        var out: [(String, Int)] = []
        try run("SELECT tag, COUNT(*) FROM item_tags GROUP BY tag ORDER BY COUNT(*) DESC, tag ASC;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                let tag = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
                out.append((tag, Int(sqlite3_column_int(st, 1))))
            }
        }
        return out
    }

    /// Map of item id → its tags (drives Library tag filtering).
    func tagsByItem() throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        try run("SELECT item_id, tag FROM item_tags ORDER BY tag;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                let id = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
                let tag = sqlite3_column_text(st, 1).map { String(cString: $0) } ?? ""
                out[id, default: []].append(tag)
            }
        }
        return out
    }

    // MARK: Chat threads & messages

    func upsertThread(_ t: ChatThread) throws {
        try run("INSERT OR REPLACE INTO threads (id,title,created_at,updated_at,pinned) VALUES (?,?,?,?,?);") { st in
            bindText(st, 1, t.id); bindText(st, 2, t.title)
            sqlite3_bind_double(st, 3, t.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(st, 4, t.updatedAt.timeIntervalSince1970)
            sqlite3_bind_int(st, 5, t.pinned ? 1 : 0)
            try step(st)
        }
    }

    /// Pinned threads first, then most-recently-updated.
    func allThreads() throws -> [ChatThread] {
        var out: [ChatThread] = []
        try run("SELECT id,title,created_at,updated_at,pinned FROM threads ORDER BY pinned DESC, updated_at DESC;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(ChatThread(
                    id: Self.col(st, 0), title: Self.col(st, 1),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)),
                    pinned: sqlite3_column_int(st, 4) != 0))
            }
        }
        return out
    }

    /// Threads whose title OR any message content matches `query` (pinned first).
    func searchThreads(query: String) throws -> [ChatThread] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return try allThreads() }
        let escaped = q
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        var out: [ChatThread] = []
        try run("""
        SELECT DISTINCT t.id, t.title, t.created_at, t.updated_at, t.pinned
        FROM threads t LEFT JOIN messages m ON m.thread_id = t.id
        WHERE t.title LIKE ?1 ESCAPE '\\' OR m.content LIKE ?1 ESCAPE '\\'
        ORDER BY t.pinned DESC, t.updated_at DESC;
        """) { st in
            bindText(st, 1, pattern)
            while sqlite3_step(st) == SQLITE_ROW {
                out.append(ChatThread(
                    id: Self.col(st, 0), title: Self.col(st, 1),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 2)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 3)),
                    pinned: sqlite3_column_int(st, 4) != 0))
            }
        }
        return out
    }

    func setThreadPinned(id: String, pinned: Bool) throws {
        try run("UPDATE threads SET pinned = ? WHERE id = ?;") { st in
            sqlite3_bind_int(st, 1, pinned ? 1 : 0); bindText(st, 2, id); try step(st)
        }
    }

    func updateThreadTitle(id: String, title: String) throws {
        try run("UPDATE threads SET title = ? WHERE id = ?;") { st in
            bindText(st, 1, title); bindText(st, 2, id); try step(st)
        }
    }

    func deleteThread(id: String) throws {
        try run("DELETE FROM threads WHERE id = ?;") { st in bindText(st, 1, id); try step(st) }
    }

    /// Replace all stored messages for a thread (simple + correct for our sizes).
    func saveMessages(_ messages: [ChatMessage], threadID: String) throws {
        try exec("BEGIN;")
        do {
            try run("DELETE FROM messages WHERE thread_id = ?;") { st in bindText(st, 1, threadID); try step(st) }
            let enc = JSONEncoder()
            for (i, m) in messages.enumerated() {
                let cj = (try? enc.encode(m.citations)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                try run("INSERT INTO messages (id,thread_id,ord,role,content,citations_json,model,reasoning) VALUES (?,?,?,?,?,?,?,?);") { st in
                    bindText(st, 1, "\(threadID)#\(i)"); bindText(st, 2, threadID)
                    sqlite3_bind_int(st, 3, Int32(i))
                    bindText(st, 4, m.role.rawValue); bindText(st, 5, m.content); bindText(st, 6, cj)
                    bindText(st, 7, m.model); bindText(st, 8, m.reasoning)
                    try step(st)
                }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
    }

    func loadMessages(threadID: String) throws -> [ChatMessage] {
        var out: [ChatMessage] = []
        let dec = JSONDecoder()
        try run("SELECT role,content,citations_json,model,reasoning FROM messages WHERE thread_id = ? ORDER BY ord;") { st in
            bindText(st, 1, threadID)
            while sqlite3_step(st) == SQLITE_ROW {
                let role = ChatMessageRole(rawValue: Self.col(st, 0)) ?? .assistant
                let content = Self.col(st, 1)
                let cites = (Self.col(st, 2).data(using: .utf8)).flatMap { try? dec.decode([Citation].self, from: $0) } ?? []
                out.append(ChatMessage(role: role, content: content, citations: cites,
                                       model: Self.col(st, 3), reasoning: Self.col(st, 4)))
            }
        }
        return out
    }

    /// Persist a thread's compaction summary covering `messages[0..<boundary]`.
    func saveThreadSummary(threadID: String, boundary: Int, summary: String, now: Date = Date()) throws {
        try run("INSERT OR REPLACE INTO thread_summaries (thread_id,boundary,summary,updated_at) VALUES (?,?,?,?);") { st in
            bindText(st, 1, threadID); sqlite3_bind_int(st, 2, Int32(boundary))
            bindText(st, 3, summary); sqlite3_bind_double(st, 4, now.timeIntervalSince1970)
            try step(st)
        }
    }

    /// Drop a thread's compaction summary (so the next turn recompacts from scratch).
    func deleteThreadSummary(threadID: String) throws {
        try run("DELETE FROM thread_summaries WHERE thread_id = ?;") { st in bindText(st, 1, threadID); try step(st) }
    }

    // MARK: Pinned facts (long-term memory)

    /// Pin a fact to long-term memory (deduped by text, case-insensitive).
    func addPinnedFact(_ fact: String, idSeed: String = UUID().uuidString, now: Date = Date()) throws {
        let f = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !f.isEmpty else { return }
        if try allPinnedFacts().contains(where: { $0.fact.lowercased() == f.lowercased() }) { return }
        try run("INSERT INTO pinned_facts (id,fact,created_at) VALUES (?,?,?);") { st in
            bindText(st, 1, idSeed); bindText(st, 2, f); sqlite3_bind_double(st, 3, now.timeIntervalSince1970)
            try step(st)
        }
    }

    /// All pinned facts, oldest first.
    func allPinnedFacts() throws -> [(id: String, fact: String)] {
        var out: [(id: String, fact: String)] = []
        try run("SELECT id,fact FROM pinned_facts ORDER BY created_at;") { st in
            while sqlite3_step(st) == SQLITE_ROW { out.append((Self.col(st, 0), Self.col(st, 1))) }
        }
        return out
    }

    func removePinnedFact(id: String) throws {
        try run("DELETE FROM pinned_facts WHERE id = ?;") { st in bindText(st, 1, id); try step(st) }
    }

    /// The stored compaction summary for a thread, or nil if none yet.
    func loadThreadSummary(threadID: String) throws -> (boundary: Int, summary: String)? {
        var result: (Int, String)?
        try run("SELECT boundary,summary FROM thread_summaries WHERE thread_id = ?;") { st in
            bindText(st, 1, threadID)
            if sqlite3_step(st) == SQLITE_ROW { result = (Int(sqlite3_column_int(st, 0)), Self.col(st, 1)) }
        }
        return result
    }

    // MARK: Writes

    /// Insert/replace an item and (re)build its chunks atomically.
    func upsert(item: KnowledgeItem, chunks: [Chunk]) throws {
        try exec("BEGIN;")
        do {
            try run("""
            INSERT OR REPLACE INTO items
            (id,path,title,kind,content_hash,byte_size,created_at,modified_at,summary)
            VALUES (?,?,?,?,?,?,?,?,?);
            """) { st in
                bindText(st, 1, item.id);   bindText(st, 2, item.path)
                bindText(st, 3, item.title); bindText(st, 4, item.kind.rawValue)
                bindText(st, 5, item.contentHash)
                sqlite3_bind_int64(st, 6, item.byteSize)
                sqlite3_bind_double(st, 7, item.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(st, 8, item.modifiedAt.timeIntervalSince1970)
                bindText(st, 9, item.summary)
                try step(st)
            }
            try run("DELETE FROM chunks WHERE item_id = ?;") { st in
                bindText(st, 1, item.id); try step(st)
            }
            for c in chunks {
                try run("INSERT INTO chunks (id,item_id,ord,text,embedding) VALUES (?,?,?,?,?);") { st in
                    bindText(st, 1, c.id); bindText(st, 2, c.itemID)
                    sqlite3_bind_int(st, 3, Int32(c.ordinal))
                    bindText(st, 4, c.text)
                    bindBlob(st, 5, Self.encode(c.embedding))
                    try step(st)
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Wipe all ingested knowledge (items → chunks/tags/citations cascade).
    /// Leaves chat threads and saved searches intact.
    func clearItems() throws {
        try exec("DELETE FROM items;")
    }

    /// Delete every item whose source path is inside `pathPrefix` (a folder).
    /// Returns the number of items removed (chunks/tags/citations cascade).
    @discardableResult
    func deleteItemsUnder(pathPrefix: String) throws -> Int {
        let escaped = pathPrefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = escaped + "/%"
        try run("DELETE FROM items WHERE path LIKE ? ESCAPE '\\';") { st in
            bindText(st, 1, pattern); try step(st)
        }
        return Int(sqlite3_changes(db))
    }

    /// Recompute every chunk's embedding from its stored text (e.g. after an
    /// embedding-model change). Returns the number of chunks re-embedded.
    @discardableResult
    func reembedAll(_ embed: @Sendable (String) -> [Float]) throws -> Int {
        var rows: [(id: String, text: String)] = []
        try run("SELECT id, text FROM chunks;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                rows.append((Self.col(st, 0), Self.col(st, 1)))
            }
        }
        try exec("BEGIN;")
        do {
            for row in rows {
                let v = embed(row.text)
                guard !v.isEmpty else { continue }
                try run("UPDATE chunks SET embedding = ? WHERE id = ?;") { st in
                    bindBlob(st, 1, Self.encode(v)); bindText(st, 2, row.id); try step(st)
                }
            }
            try exec("COMMIT;")
        } catch { try? exec("ROLLBACK;"); throw error }
        return rows.count
    }

    /// Delete items by id; their chunks cascade away (FK ON DELETE CASCADE).
    func deleteItems(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try run("DELETE FROM items WHERE id = ?;") { st in
                bindText(st, 1, id); try step(st)
            }
        }
    }

    /// Existing content hash for a path, if any (drives incremental ingest).
    func contentHash(forPath path: String) throws -> String? {
        var result: String?
        try run("SELECT content_hash FROM items WHERE path = ? LIMIT 1;") { st in
            bindText(st, 1, path)
            if sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) {
                result = String(cString: c)
            }
        }
        return result
    }

    // MARK: Reads

    func itemCount() throws -> Int { try scalarCount("SELECT COUNT(*) FROM items;") }
    func chunkCount() throws -> Int { try scalarCount("SELECT COUNT(*) FROM chunks;") }

    /// Aggregate snapshot of the whole knowledge base for the Insights view.
    func stats() throws -> KnowledgeStats {
        let items = try scalarCount("SELECT COUNT(*) FROM items;")
        let chunks = try scalarCount("SELECT COUNT(*) FROM chunks;")
        let threads = try scalarCount("SELECT COUNT(*) FROM threads;")
        let tags = try scalarCount("SELECT COUNT(DISTINCT tag) FROM item_tags;")

        var totalBytes: Int64 = 0
        var oldest: Date?, newest: Date?
        try run("SELECT COALESCE(SUM(byte_size),0), MIN(modified_at), MAX(modified_at) FROM items;") { st in
            if sqlite3_step(st) == SQLITE_ROW {
                totalBytes = sqlite3_column_int64(st, 0)
                if sqlite3_column_type(st, 1) != SQLITE_NULL {
                    oldest = Date(timeIntervalSince1970: sqlite3_column_double(st, 1))
                    newest = Date(timeIntervalSince1970: sqlite3_column_double(st, 2))
                }
            }
        }

        var byKind: [(kind: ItemKind, count: Int)] = []
        try run("SELECT kind, COUNT(*) FROM items GROUP BY kind ORDER BY COUNT(*) DESC;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                let raw = sqlite3_column_text(st, 0).map { String(cString: $0) } ?? ""
                byKind.append((ItemKind(rawValue: raw) ?? .unknown, Int(sqlite3_column_int(st, 1))))
            }
        }

        return KnowledgeStats(itemCount: items, chunkCount: chunks, threadCount: threads,
                              tagCount: tags, totalBytes: totalBytes, byKind: byKind,
                              oldest: oldest, newest: newest, activity: try ingestActivity(days: 30),
                              topCited: try mostCited(limit: 5))
    }

    /// Items modified per 24h bucket over the last `days` (index 0 = oldest day,
    /// last index = today). Drives the Insights activity sparkline.
    func ingestActivity(days: Int = 30) throws -> [Int] {
        let now = Date().timeIntervalSince1970
        var buckets = [Int](repeating: 0, count: days)
        try run("SELECT modified_at FROM items;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                let t = sqlite3_column_double(st, 0)
                let daysAgo = Int((now - t) / 86_400)
                if daysAgo >= 0, daysAgo < days { buckets[days - 1 - daysAgo] += 1 }
            }
        }
        return buckets
    }

    func allItems() throws -> [KnowledgeItem] {
        var items: [KnowledgeItem] = []
        try run("SELECT id,path,title,kind,content_hash,byte_size,created_at,modified_at,summary FROM items ORDER BY modified_at DESC;") { st in
            while sqlite3_step(st) == SQLITE_ROW { items.append(Self.readItem(st)) }
        }
        return items
    }

    /// Items most similar to a given item, by the centroid of its chunk
    /// embeddings (excludes the item itself). Powers "Related" browsing.
    func relatedItems(to itemID: String, k: Int = 5) throws -> [RetrievedChunk] {
        var sum: [Float] = []
        var n = 0
        try run("SELECT embedding FROM chunks WHERE item_id = ?;") { st in
            bindText(st, 1, itemID)
            while sqlite3_step(st) == SQLITE_ROW {
                let bytes = sqlite3_column_bytes(st, 0)
                let blob = sqlite3_column_blob(st, 0)
                let data = (blob != nil && bytes > 0) ? Data(bytes: blob!, count: Int(bytes)) : Data()
                let v = Self.decode(data)
                guard !v.isEmpty else { continue }
                if sum.isEmpty { sum = v } else if v.count == sum.count {
                    for i in 0..<sum.count { sum[i] += v[i] }
                }
                n += 1
            }
        }
        guard n > 0, !sum.isEmpty else { return [] }
        let centroid = Embedder.normalize(sum.map { $0 / Float(n) })
        let hits = try search(vector: centroid, k: k + 8, maxPerItem: 1)
        return Array(hits.filter { $0.item.id != itemID }.prefix(k))
    }

    /// Ids of items whose chunk text contains `query` (full-text Library search).
    func itemIDsMatchingContent(_ query: String) throws -> Set<String> {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let escaped = q
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        var out = Set<String>()
        try run("SELECT DISTINCT item_id FROM chunks WHERE text LIKE ? ESCAPE '\\';") { st in
            bindText(st, 1, "%\(escaped)%")
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 0) { out.insert(String(cString: c)) }
            }
        }
        return out
    }

    /// The text of every chunk for one item, in order (drives the detail view).
    func chunkTexts(forItem itemID: String) throws -> [String] {
        var texts: [String] = []
        try run("SELECT text FROM chunks WHERE item_id = ? ORDER BY ord;") { st in
            bindText(st, 1, itemID)
            while sqlite3_step(st) == SQLITE_ROW {
                if let c = sqlite3_column_text(st, 0) { texts.append(String(cString: c)) }
            }
        }
        return texts
    }

    /// Hybrid top-k search: cosine similarity blended with a keyword-overlap
    /// boost so exact terms (names, codes, filenames) that embeddings miss still
    /// surface. `maxPerItem` caps how many chunks one file may contribute.
    /// Pass `queryText` to enable the keyword signal (empty = pure vector).
    func search(vector query: [Float], queryText: String = "", k: Int = 8,
                maxPerItem: Int = 2, keywordWeight: Float = 0.3) throws -> [RetrievedChunk] {
        let items = try allItems()
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let terms = Self.keywordTerms(queryText)

        // IDF per term so distinctive names/codes outweigh common words. Terms that
        // appear in NO document are dropped (they'd only dilute the score).
        var idf: [String: Float] = [:]
        if !terms.isEmpty {
            let total = Float(max(items.count, 1))
            for t in terms {
                let df = (try? itemIDsMatchingContent(t).count) ?? 0
                if df > 0 { idf[t] = log((total + 1) / (Float(df) + 1)) + 0.5 }
            }
        }
        // The English embedder can't meaningfully vectorise CJK text, so for a CJK
        // query its vector is noise — fall back to keyword-only ranking.
        let cjkQuery = queryText.unicodeScalars.contains(where: Self.isCJK)
        let useVector = !query.isEmpty && !cjkQuery
        guard useVector || !idf.isEmpty else { return [] }
        // Without a usable vector, the keyword signal must carry the ranking.
        let kw = useVector ? keywordWeight : max(keywordWeight, 1)

        var scored: [(Chunk, Float)] = []
        try run("SELECT id,item_id,ord,text,embedding FROM chunks;") { st in
            while sqlite3_step(st) == SQLITE_ROW {
                let chunk = Self.readChunk(st)
                var score = useVector ? Embedder.cosine(query, chunk.embedding) : 0
                if !idf.isEmpty {
                    score += kw * Self.keywordScore(text: chunk.text, idf: idf)
                }
                scored.append((chunk, score))
            }
        }

        var perItem: [String: Int] = [:]
        var out: [RetrievedChunk] = []
        for (chunk, score) in scored.sorted(by: { $0.1 > $1.1 }) {
            guard out.count < k else { break }
            // In keyword-only mode a zero score means no term matched — stop rather
            // than pad the results with irrelevant chunks.
            if !useVector && score <= 0 { break }
            let used = perItem[chunk.itemID, default: 0]
            guard used < maxPerItem, let item = byID[chunk.itemID] else { continue }
            perItem[chunk.itemID] = used + 1
            out.append(RetrievedChunk(chunk: chunk, item: item, score: score))
        }
        return out
    }

    private static let searchStopwords: Set<String> = [
        "the", "and", "for", "are", "was", "with", "that", "this", "what", "how",
        "does", "did", "you", "your", "can", "about", "from", "into", "over",
        // common short words (we keep len-2 tokens like codes/abbreviations)
        "is", "be", "of", "in", "on", "at", "by", "to", "it", "as", "or", "an",
        "we", "my", "me", "do", "if", "so", "no", "up", "us"
    ]

    /// Distinct meaningful lowercase terms from the query (len ≥ 2, no stopwords).
    /// Uses `NLTokenizer`, which segments CJK (Chinese/Japanese/Korean) into words —
    /// so "彩虹猫的相关内容" yields {彩虹, 虹猫, 相关, 内容} instead of one un-matchable
    /// blob (the bug that made non-English searches return nothing).
    static func keywordTerms(_ query: String) -> Set<String> {
        var terms = Set<String>()
        let lower = query.lowercased()
        // Latin / numeric words via the tokenizer.
        let tok = NLTokenizer(unit: .word)
        tok.string = lower
        tok.enumerateTokens(in: lower.startIndex..<lower.endIndex) { range, _ in
            let t = String(lower[range])
            if t.count >= 2, !searchStopwords.contains(t),
               !t.unicodeScalars.contains(where: isCJK) { terms.insert(t) }
            return true
        }
        // CJK → character BIGRAMS. Word segmentation (and proper names)
        // are unreliable, but a CJK bigram robustly matches the document.
        var run: [Character] = []
        func flush() {
            if run.count >= 2 {
                for i in 0..<(run.count - 1) { terms.insert(String(run[i...(i + 1)])) }
            }
            run.removeAll(keepingCapacity: true)
        }
        for ch in lower {
            if ch.unicodeScalars.allSatisfy(isCJK) { run.append(ch) } else { flush() }
        }
        flush()
        return terms
    }

    /// CJK ideograph ranges (Chinese/Japanese/Korean Han characters).
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2EBEF: return true
        default: return false
        }
    }

    /// Fraction of query terms present in `text` (0…1). Unweighted; retained for
    /// callers/tests that want a simple overlap. `search` uses `keywordScore`.
    static func keywordOverlap(text: String, terms: Set<String>) -> Float {
        guard !terms.isEmpty else { return 0 }
        let lower = text.lowercased()
        let hits = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        return Float(hits) / Float(terms.count)
    }

    /// IDF-weighted keyword score in 0…1: a chunk gets credit for the query terms it
    /// contains, weighted so DISTINCTIVE terms (a rare proper noun) count far more
    /// than common words (内容, "report"). Without this, common words drown out the
    /// one term that actually identifies the document.
    static func keywordScore(text: String, idf: [String: Float]) -> Float {
        guard !idf.isEmpty else { return 0 }
        let lower = text.lowercased()
        var hit: Float = 0, total: Float = 0
        for (term, w) in idf { total += w; if lower.contains(term) { hit += w } }
        return total > 0 ? hit / total : 0
    }

    // MARK: - Row readers

    private static func readItem(_ st: OpaquePointer?) -> KnowledgeItem {
        KnowledgeItem(
            id: col(st, 0), path: col(st, 1), title: col(st, 2),
            kind: ItemKind(rawValue: col(st, 3)) ?? .unknown,
            contentHash: col(st, 4),
            byteSize: sqlite3_column_int64(st, 5),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 6)),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 7)),
            summary: col(st, 8))
    }

    private static func readChunk(_ st: OpaquePointer?) -> Chunk {
        let bytes = sqlite3_column_bytes(st, 4)
        let blob = sqlite3_column_blob(st, 4)
        let data = (blob != nil && bytes > 0) ? Data(bytes: blob!, count: Int(bytes)) : Data()
        return Chunk(id: col(st, 0), itemID: col(st, 1),
                     ordinal: Int(sqlite3_column_int(st, 2)), text: col(st, 3),
                     embedding: decode(data))
    }

    private static func col(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    // MARK: - Embedding BLOB codec (Float32 little-endian)

    static func encode(_ v: [Float]) -> Data {
        var v = v
        return v.withUnsafeMutableBufferPointer { Data(buffer: $0) }
    }
    static func decode(_ data: Data) -> [Float] {
        guard !data.isEmpty else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    // MARK: - Low-level SQLite helpers

    private func exec(_ sql: String) throws { try Self.execRaw(db, sql) }

    private static func execRaw(_ db: OpaquePointer?, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.exec(msg)
        }
    }

    private func scalarCount(_ sql: String) throws -> Int {
        var n = 0
        try run(sql) { st in if sqlite3_step(st) == SQLITE_ROW { n = Int(sqlite3_column_int(st, 0)) } }
        return n
    }

    /// Prepare, hand the statement to `body` (which binds and steps), then
    /// finalize. Read bodies loop with `sqlite3_step`; write bodies call `step`.
    private func run(_ sql: String, _ body: (OpaquePointer?) throws -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)), sql)
        }
        defer { sqlite3_finalize(st) }
        try body(st)
    }

    /// Execute a write statement once, expecting completion.
    private func step(_ st: OpaquePointer?) throws {
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ st: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(st, idx, value, -1, Self.TRANSIENT)
    }
    private func bindBlob(_ st: OpaquePointer?, _ idx: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(st, idx, raw.baseAddress, Int32(raw.count), Self.TRANSIENT)
        }
    }
}

enum StoreError: Error, LocalizedError {
    case open(String), exec(String), prepare(String, String), step(String)
    var errorDescription: String? {
        switch self {
        case .open(let m): return "sqlite open: \(m)"
        case .exec(let m): return "sqlite exec: \(m)"
        case .prepare(let m, let s): return "sqlite prepare: \(m) — \(s)"
        case .step(let m): return "sqlite step: \(m)"
        }
    }
}
