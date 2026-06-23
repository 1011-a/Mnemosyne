import Foundation
import Fathom

/// Formatting / presentation / inspection tool handlers (charts, case styles, slugs, lists, URL &
/// JWT inspection, word frequency), extracted from `ToolAgent`'s main `handleTool` switch to keep
/// that file focused. Pure value-in/value-out (no store/network/UI). `handleFormatTool` returns nil
/// when `name` isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleFormatTool(_ name: String, args: String) -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "bar_chart":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (label: value pairs).", []) }
            guard let chart = AsciiChart.render(data) else {
                return ("Couldn't parse any 'label: value' pairs from the data. Example: 'Jan: 8, Feb: 5'.", [])
            }
            return ("```\n\(chart)\n```", [])

        case "parse_url":
            guard let url = arg("url"), !url.isEmpty else { return ("Missing 'url'.", []) }
            guard let summary = URLParser.summary(url) else {
                return ("'\(url)' doesn't look like a valid URL.", [])
            }
            return ("URL parts:\n\(summary)", [])

        case "jwt_decode":
            guard let token = arg("token"), !token.isEmpty else { return ("Missing 'token'.", []) }
            guard let decoded = JWTDecoder.decode(token) else {
                return ("That doesn't look like a valid JWT (expected header.payload.signature, base64url).", [])
            }
            let header = JWTDecoder.prettify(decoded.header)
            let payload = JWTDecoder.prettify(decoded.payload)
            return ("Header:\n```json\n\(header)\n```\nPayload:\n```json\n\(payload)\n```\n_(Signature not verified.)_", [])

        case "slugify":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let slug = Slugifier.slugify(text)
            guard !slug.isEmpty else { return ("'\(text)' has no slug-able characters (try a title with letters/digits).", []) }
            return (slug, [])

        case "make_checklist":
            guard let data = arg("data"), !data.isEmpty else { return ("Missing 'data' (a list of items).", []) }
            guard let checklist = ChecklistBuilder.build(data) else {
                return ("No items to turn into a checklist. Pass items one per line.", [])
            }
            return (checklist, [])

        case "format_list":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let style = arg("style"), let out = ListFormatter.format(text, style: style) else {
                return ("Couldn't format the list. Use style 'numbered', 'bullet', 'comma', or 'and', with items one per line.", [])
            }
            return (out, [])

        case "change_case":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let mode = arg("mode"), let result = CaseConverter.convert(text, mode: mode) else {
                return ("Unknown case mode. Use 'upper', 'lower', 'title', or 'sentence'.", [])
            }
            return (result, [])

        case "headline_case":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            return (Fathom.HeadlineCase.titleize(text), [])

        case "acronym":
            guard let phrase = arg("phrase"), !phrase.isEmpty else { return ("Missing 'phrase'.", []) }
            let skipMinor = (arg("skip_minor") ?? "false").lowercased() == "true"
            let acronym = Fathom.Acronym.make(phrase, skipMinor: skipMinor)
            guard !acronym.isEmpty else { return ("No letters to acronymize in '\(phrase)'.", []) }
            return ("\(phrase) → \(acronym)", [])

        case "case_style":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let style = arg("style"), let out = CaseStyle.convert(text, style: style), !out.isEmpty else {
                return ("Use style 'snake', 'camel', 'kebab', or 'pascal' with an identifier.", [])
            }
            return (out, [])

        case "word_frequency":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            let n = Int(arg("top") ?? "") ?? 10
            guard let summary = WordFrequency.summary(text, n: n) else {
                return ("No content words found (after removing short/stop words).", [])
            }
            return (summary, [])

        default:
            return nil
        }
    }
}
