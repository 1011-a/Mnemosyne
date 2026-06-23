import Foundation

/// Text utility / comparison tool handlers, extracted from `ToolAgent`'s main `handleTool` switch
/// to keep that file focused. Pure value-in/value-out (no store/network/UI). `handleTextTool`
/// returns nil when `name` isn't one of these, letting the caller fall through. (These map 1:1 to
/// Fathom built-in tools — `word_count`/`text_transform` already exist in Fathom's `TextTools`.)
extension ToolAgent {
    func handleTextTool(_ name: String, args: String) -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "count_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return (TextCounts.report(text), [])

        case "unicode_info":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let glyphs = UnicodeInfo.inspect(text)
            guard !glyphs.isEmpty else { return ("Nothing to inspect.", []) }
            return ("```\n\(UnicodeInfo.table(glyphs))\n```", [])

        case "count_occurrences":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let needle = arg("needle"), !needle.isEmpty else { return ("Missing 'needle' (what to count).", []) }
            let cs = (arg("case_sensitive") ?? "false").lowercased() == "true"
            let ww = (arg("whole_word") ?? "false").lowercased() == "true"
            guard let n = OccurrenceCounter.count(in: text, needle: needle, caseSensitive: cs, wholeWord: ww) else {
                return ("Nothing to count.", [])
            }
            return ("'\(needle)' appears \(n) time\(n == 1 ? "" : "s")\(ww ? " (whole word)" : "")\(cs ? " (case-sensitive)" : "").", [])

        case "palindrome":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let yes = Palindrome.isPalindrome(text)
            return ("'\(text)' is \(yes ? "a palindrome" : "not a palindrome").", [])

        case "anagram":
            guard let a = arg("a"), !a.isEmpty, let b = arg("b"), !b.isEmpty else {
                return ("Need two phrases ('a' and 'b') to compare.", [])
            }
            let yes = Anagram.isAnagram(a, b)
            return ("'\(a)' and '\(b)' are \(yes ? "anagrams" : "NOT anagrams").", [])

        case "reverse":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return ((arg("mode") ?? "chars").lowercased() == "words" ? Reverse.words(text) : Reverse.chars(text), [])

        case "truncate":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let length = Int(arg("length") ?? ""), length > 0 else { return ("Need a positive 'length'.", []) }
            let byWords = (arg("mode") ?? "chars").lowercased() == "words"
            return (byWords ? Truncate.toWords(text, length) : Truncate.toChars(text, length), [])

        case "replace_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let find = arg("find"), !find.isEmpty else { return ("Missing 'find'.", []) }
            let replacement = arg("replace") ?? ""
            let ci = (arg("case_insensitive") ?? "false").lowercased() == "true"
            let (out, count) = TextReplace.replace(text, find: find, with: replacement, caseInsensitive: ci)
            guard count > 0 else { return ("No occurrences of '\(find)' found — text unchanged.", []) }
            return ("\(out)\n\n(\(count) replacement\(count == 1 ? "" : "s"))", [])

        case "extract_between":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let start = arg("start"), !start.isEmpty, let end = arg("end"), !end.isEmpty else {
                return ("Need non-empty 'start' and 'end' markers.", [])
            }
            guard let summary = TextBetween.summary(text, start: start, end: end) else {
                return ("No text found between '\(start)' and '\(end)'.", [])
            }
            return (summary, [])

        case "reindent":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            switch (arg("mode") ?? "").lowercased() {
            case "indent":
                let spaces = Int(arg("spaces") ?? "") ?? 2
                return (TextIndent.indent(text, spaces: spaces), [])
            case "dedent":
                return (TextIndent.dedent(text), [])
            default:
                return ("Set mode to 'indent' or 'dedent'.", [])
            }

        case "wrap_text":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let width = Int(arg("width") ?? "") ?? 80
            return (TextWrap.wrap(text, width: max(1, width)), [])

        case "word_diff":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' texts.", []) }
            return (WordDiff.summary(a, b), [])

        case "line_diff":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' texts.", []) }
            let d = LineDiff.diff(a, b)
            if d.added == 0 && d.removed == 0 { return ("No differences — the two texts are identical.", []) }
            return ("\(d.added) added, \(d.removed) removed:\n```\n\(d.lines.joined(separator: "\n"))\n```", [])

        case "text_similarity":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' texts.", []) }
            let pct = Int((Similarity.jaccard(a, b) * 100).rounded())
            return ("Similarity: \(pct)% (Jaccard word overlap).", [])

        case "edit_distance":
            guard let a = arg("a"), let b = arg("b") else { return ("Need 'a' and 'b' strings.", []) }
            let dist = Levenshtein.distance(a, b)
            let pct = Int((Levenshtein.ratio(a, b) * 100).rounded())
            return ("Edit distance: \(dist) (\(pct)% similar).", [])

        default:
            return nil
        }
    }
}
