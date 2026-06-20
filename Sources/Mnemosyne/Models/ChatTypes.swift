import Foundation

/// Shared chat primitives used by the agent brain and UI.
enum ChatMessageRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

struct ChatMessage: Codable, Sendable, Identifiable {
    var id = UUID()
    var role: ChatMessageRole
    var content: String
    /// Optional provenance attached to an assistant turn for UI citations.
    var citations: [Citation] = []
    /// The DeepSeek model that produced an assistant turn (empty for user turns).
    var model: String = ""
    /// The reasoner's thinking trace, if any (deepseek-reasoner only).
    var reasoning: String = ""

    enum CodingKeys: String, CodingKey { case role, content }

    init(role: ChatMessageRole, content: String, citations: [Citation] = [],
         model: String = "", reasoning: String = "") {
        self.role = role; self.content = content; self.citations = citations
        self.model = model; self.reasoning = reasoning
    }
}

struct Citation: Codable, Sendable, Hashable, Identifiable {
    var id = UUID()
    var index: Int
    var title: String
    var path: String
    var snippet: String
    /// The knowledge item this citation came from (for usage tracking).
    var itemID: String = ""

    init(index: Int, title: String, path: String, snippet: String, itemID: String = "") {
        self.index = index; self.title = title; self.path = path
        self.snippet = snippet; self.itemID = itemID
    }

    enum CodingKeys: String, CodingKey { case index, title, path, snippet, itemID }
}

extension Citation {
    /// A clean, whitespace-collapsed preview of the cited passage — shown in the
    /// answer card so you can see what each source actually contributed.
    var snippetPreview: String {
        snippet
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ChatMessage {
    /// What the Copy button puts on the clipboard: the answer plus a self-contained
    /// "Sources" list (so a pasted answer carries its provenance).
    var copyableText: String {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !citations.isEmpty else { return text }
        text += "\n\nSources:\n"
        text += citations.map { c in
            var line = "[\(c.index)] \(c.title)"
            if !c.snippetPreview.isEmpty { line += " — \(c.snippetPreview)" }
            return line
        }.joined(separator: "\n")
        return text
    }
}
