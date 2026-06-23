import Foundation
import Fathom

/// Encoding / cipher tool handlers, extracted from `ToolAgent`'s main `handleTool` switch to keep
/// that file focused. Pure value-in/value-out (no store/network/UI). `handleEncodingTool` returns
/// nil when `name` isn't one of these, letting the caller fall through. The cipher helpers now come
/// from the Fathom SDK (`Fathom.Caesar`/`Vigenere`/`Morse`) — the app's duplicate helpers were
/// deleted in the migration.
extension ToolAgent {
    func handleEncodingTool(_ name: String, args: String) -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "hash_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return ("SHA-256: \(HashUtil.sha256(text))\nShort: \(HashUtil.short(text))", [])

        case "base64":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            if (arg("mode") ?? "encode").lowercased() == "decode" {
                guard let decoded = Base64Util.decode(text) else {
                    return ("That isn't valid base64 (or the bytes aren't UTF-8 text).", [])
                }
                return (decoded, [])
            }
            return (Base64Util.encode(text), [])

        case "html_entities":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let unescape = (arg("mode") ?? "escape").lowercased() == "unescape"
            return (unescape ? HTMLEntities.unescape(text) : HTMLEntities.escape(text), [])

        case "url_encode":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            if (arg("mode") ?? "encode").lowercased() == "decode" {
                guard let decoded = URLEncoding.decode(text) else { return ("That has malformed percent-encoding.", []) }
                return (decoded, [])
            }
            return (URLEncoding.encode(text), [])

        case "caesar":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let n = Int(arg("shift") ?? "") ?? 13
            return (Fathom.Caesar.shift(text, by: n), [])

        case "nato":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let spelled = NatoPhonetic.spell(text) else { return ("Nothing to spell.", []) }
            return (spelled, [])

        case "vigenere":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let key = arg("key"), !key.isEmpty else { return ("Missing 'key' (the keyword).", []) }
            let decode = (arg("mode") ?? "encode").lowercased() == "decode"
            guard let out = Fathom.Vigenere.transform(text, key: key, decode: decode) else {
                return ("The key must contain at least one letter.", [])
            }
            return (out, [])

        case "char_frequency":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let rows = CharFrequency.analyze(text)
            guard !rows.isEmpty else { return ("No letters to analyze.", []) }
            let top = Swift.min(Swift.max(Int(arg("top") ?? "") ?? 26, 1), 26)
            return ("```\n\(CharFrequency.table(rows, limit: top))\n```", [])

        case "morse":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let mode = (arg("mode") ?? "").lowercased()
            // Auto-detect: text made only of . - / and whitespace is Morse → decode.
            let looksLikeMorse = text.allSatisfy { ".-/ \n\t".contains($0) }
            let decode = mode == "decode" || (mode != "encode" && looksLikeMorse)
            if decode {
                guard let out = Fathom.Morse.decode(text) else { return ("Couldn't decode any Morse.", []) }
                return (out, [])
            }
            guard let out = Fathom.Morse.encode(text) else { return ("Nothing encodable to Morse.", []) }
            return ("```\n\(out)\n```", [])

        default:
            return nil
        }
    }
}
