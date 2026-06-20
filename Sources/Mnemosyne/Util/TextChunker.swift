import Foundation
import CryptoKit

/// Splits extracted text into overlapping, embed-sized chunks on natural
/// boundaries (paragraph → sentence → hard split). Overlap preserves context
/// across boundaries so retrieval doesn't lose the thread.
enum TextChunker {
    static func chunks(from text: String,
                       targetChars: Int = 900,
                       overlapChars: Int = 150) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        if normalized.count <= targetChars { return [normalized] }

        // Break into paragraphs, then greedily pack toward the target size.
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var chunks: [String] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(t) }
            current = ""
        }
        for para in paragraphs {
            if para.count > targetChars {
                flush()
                chunks.append(contentsOf: hardSplit(para, targetChars: targetChars, overlapChars: overlapChars))
            } else if current.count + para.count + 2 > targetChars {
                flush()
                current = para
            } else {
                current += current.isEmpty ? para : "\n\n" + para
            }
        }
        flush()
        return applyOverlap(chunks, overlapChars: overlapChars)
    }

    private static func hardSplit(_ s: String, targetChars: Int, overlapChars: Int) -> [String] {
        var out: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: targetChars, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[idx..<end]))
            if end == s.endIndex { break }
            idx = s.index(end, offsetBy: -overlapChars, limitedBy: idx) ?? end
        }
        return out
    }

    /// Prepend a tail of the previous chunk to each chunk for continuity.
    private static func applyOverlap(_ chunks: [String], overlapChars: Int) -> [String] {
        guard overlapChars > 0, chunks.count > 1 else { return chunks }
        var out: [String] = []
        for (i, c) in chunks.enumerated() {
            if i == 0 { out.append(c); continue }
            let prev = chunks[i - 1]
            let tail = String(prev.suffix(overlapChars))
            out.append(tail + "\n…\n" + c)
        }
        return out
    }
}

/// Content hashing for dedupe / incremental ingest.
enum Hashing {
    static func sha256(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
