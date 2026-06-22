import Foundation

/// Pulls a JSON value out of a model response for the force-JSON path (DeepSeek beta chat-prefix
/// completion seeded with a ```json fence). Robust to three shapes: a fenced ```json … ``` block,
/// a bare object/array, or prose wrapping a JSON value. Pure + deterministic → unit-testable.
/// Used by `DeepSeekClient.completeJSON`.
enum JSONExtract {
    /// Best-effort extraction of the first JSON object/array as a trimmed string. Prefers a fenced
    /// block; otherwise slices from the first `{`/`[` to the last `}`/`]`. nil when none is found.
    static func extract(from text: String) -> String? {
        if let fenced = fencedBody(text) { return slice(fenced) ?? fenced.trimmed() }
        return slice(text)
    }

    /// Like `extract`, but returns nil unless the result actually parses as JSON — use when you
    /// need a guarantee, not just a candidate.
    static func extractValid(from text: String) -> String? {
        guard let candidate = extract(from: text), isValid(candidate) else { return nil }
        return candidate
    }

    /// True when `s` is parseable JSON (object, array, or any fragment Foundation accepts).
    static func isValid(_ s: String) -> Bool {
        guard let data = s.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Inner text of the first ``` fenced block, dropping an optional language tag on the open line.
    private static func fencedBody(_ text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        let afterOpen = text[open.upperBound...]
        guard let close = afterOpen.range(of: "```") else { return nil }
        var body = String(afterOpen[..<close.lowerBound])
        // Drop a leading "json" (or other) language tag line.
        if let nl = body.firstIndex(where: \.isNewline) {
            let firstLine = body[..<nl].trimmed()
            if !firstLine.isEmpty && firstLine.allSatisfy({ $0.isLetter }) {
                body = String(body[body.index(after: nl)...])
            }
        }
        return body.trimmed()
    }

    /// Substring from the first opening bracket to its matching kind's last closing bracket.
    private static func slice(_ text: String) -> String? {
        let opens = CharacterSet(charactersIn: "{[")
        guard let startIdx = text.unicodeScalars.firstIndex(where: { opens.contains($0) }) else { return nil }
        let openScalar = text.unicodeScalars[startIdx]
        let closeChar: Character = (openScalar == "{") ? "}" : "]"
        let start = startIdx.samePosition(in: text) ?? text.startIndex
        guard let endIdx = text.lastIndex(of: closeChar), endIdx > start else { return nil }
        return String(text[start...endIdx]).trimmed()
    }
}

private extension StringProtocol {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
