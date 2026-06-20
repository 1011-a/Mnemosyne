import Foundation

/// A single ingested source — a file, note, image, page, etc. One item fans
/// out into many `Chunk`s, which are what actually get embedded & retrieved.
struct KnowledgeItem: Codable, Sendable, Identifiable, Hashable {
    var id: String                 // stable id = contentHash (dedupe key)
    var path: String               // absolute source path (or synthetic uri)
    var title: String
    var kind: ItemKind
    var contentHash: String        // sha256 of extracted text
    var byteSize: Int64
    var createdAt: Date
    var modifiedAt: Date
    var summary: String            // short LLM/Gemma-derived gist (optional)

    init(id: String, path: String, title: String, kind: ItemKind,
         contentHash: String, byteSize: Int64,
         createdAt: Date, modifiedAt: Date, summary: String = "") {
        self.id = id; self.path = path; self.title = title; self.kind = kind
        self.contentHash = contentHash; self.byteSize = byteSize
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.summary = summary
    }

    /// For `.webpage` bookmark items the `path` is a URL, not a file on disk, so
    /// they open in a browser rather than Finder. nil for ordinary file items.
    var webURL: URL? {
        guard kind == .webpage, path.lowercased().hasPrefix("http") else { return nil }
        return URL(string: path)
    }
}

enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text, markdown, code, pdf, image, richtext, html, data, audioTranscript
    case wordDoc, iwork, email, message, webpage, contact, event, unknown

    var sfSymbol: String {
        switch self {
        case .text, .richtext: return "doc.text"
        case .markdown:        return "text.alignleft"
        case .code:            return "chevron.left.forwardslash.chevron.right"
        case .pdf:             return "doc.richtext"
        case .image:           return "photo"
        case .html, .webpage:  return "globe"
        case .data:            return "tablecells"
        case .audioTranscript: return "waveform"
        case .wordDoc:         return "doc.fill"
        case .iwork:           return "doc.append"
        case .email:           return "envelope"
        case .message:         return "bubble.left.and.bubble.right"
        case .contact:         return "person.crop.circle"
        case .event:           return "calendar"
        case .unknown:         return "questionmark.square.dashed"
        }
    }
}

/// A retrievable unit of text plus its embedding vector.
struct Chunk: Codable, Sendable, Identifiable, Hashable {
    var id: String                 // "\(itemID)#\(ordinal)"
    var itemID: String
    var ordinal: Int
    var text: String
    var embedding: [Float]

    init(id: String, itemID: String, ordinal: Int, text: String, embedding: [Float]) {
        self.id = id; self.itemID = itemID; self.ordinal = ordinal
        self.text = text; self.embedding = embedding
    }
}

/// A scored search hit returned by the store and handed to the agent for RAG.
struct RetrievedChunk: Sendable, Identifiable {
    var id: String { chunk.id }
    let chunk: Chunk
    let item: KnowledgeItem
    let score: Float
}
