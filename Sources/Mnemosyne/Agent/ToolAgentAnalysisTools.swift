import Foundation

/// Analysis tool handlers — readability/text stats, PII redaction, secret scanning, key-phrase and
/// field extraction, sentiment, language detection, and the DeepSeek-backed reasoners
/// (deep_reason/fill_in/confidence_check) — extracted from `ToolAgent`'s main `handleTool` switch to
/// keep that file focused. Store/LLM-coupled (resolve an item, read its text, then run a local
/// analyzer or DeepSeek), so they live in an `extension ToolAgent` rather than migrating to Fathom.
/// `handleAnalysisTool` returns nil when `name` isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleAnalysisTool(_ name: String, args: String,
                            onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "text_stats":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Measuring \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = TextStats.report(text) else {
                return ("'\(it.title)' has no readable text to measure.", [])
            }
            return ("\(it.title): \(report)", [])

        case "task_progress":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Tallying tasks in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = ChecklistAnalyzer.report(text) else {
                return ("No markdown checklist items (- [ ] / - [x]) found in '\(it.title)'.", [])
            }
            return ("\(it.title) — \(report)", [])

        case "quick_summary":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Summarizing \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = ExtractiveSummary.summarize(text) else {
                return ("'\(it.title)' has no text to summarize.", [])
            }
            return ("Quick summary of '\(it.title)' (extractive, offline):\n\(summary)", [])

        case "extract_key_values":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading fields in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = KeyValueExtractor.summary(text) else {
                return ("No 'Key: Value' metadata fields found in '\(it.title)'.", [])
            }
            return ("Fields in '\(it.title)':\n\(summary)", [])

        case "redact_pii":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Redacting \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = Redactor.report(text) else {
                return ("No emails, phone numbers, or SSNs detected in '\(it.title)' — nothing to redact.", [])
            }
            return ("\(it.title) (redacted) — \(report)", [])

        case "scan_secrets":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Scanning \(it.title) for secrets…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let report = SecretScanner.report(text) else {
                return ("No leaked credentials detected in '\(it.title)'.", [])
            }
            return ("\(it.title) — \(report)", [])

        case "key_phrases":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding key phrases in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = PhraseExtractor.summary(text) else {
                return ("No recurring multi-word phrases found in '\(it.title)' — try keyword_extract for single terms.", [])
            }
            return ("'\(it.title)' — \(summary)", [])

        case "extract_amounts":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Totalling amounts in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = MoneyExtractor.summary(text) else {
                return ("No monetary amounts found in '\(it.title)'.", [])
            }
            return ("'\(it.title)' — \(summary)", [])

        case "extract_definitions":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding definitions in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = DefinitionExtractor.summary(text) else {
                return ("No definition sentences found in '\(it.title)'.", [])
            }
            return ("Glossary from '\(it.title)':\n\(summary)", [])

        case "extract_mentions":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding tags & mentions in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = HashtagExtractor.summary(text) else {
                return ("No #hashtags or @mentions found in '\(it.title)'.", [])
            }
            return ("'\(it.title)':\n\(summary)", [])

        case "fill_in":
            guard let prefix = arg("prefix"), !prefix.isEmpty else { return ("Missing 'prefix' (text before the gap).", []) }
            let suffix = arg("suffix") ?? ""
            guard let raw = try? await deepSeek.fillInMiddle(prompt: prefix, suffix: suffix, maxTokens: 512), !raw.isEmpty else {
                return ("Couldn't generate a fill-in (the model returned nothing).", [])
            }
            let middle = FillIn.trimSuffixEcho(raw, suffix: suffix)
            return ("```\n\(middle)\n```", [])

        case "deep_reason":
            guard let question = arg("question"), !question.isEmpty else { return ("Missing 'question'.", []) }
            onStatus(ReasonerRouter.rationale(question))
            guard let result = try? await deepSeek.reasonedAnswer(question), !result.answer.isEmpty else {
                return ("The reasoner returned no answer (it may be unavailable for this account).", [])
            }
            var out = result.answer
            if let reasoning = result.reasoning, !reasoning.isEmpty {
                out += "\n\n<details>\n<summary>Reasoning</summary>\n\n\(reasoning)\n\n</details>"
            }
            return (out, [])

        case "confidence_check":
            guard let question = arg("question"), !question.isEmpty else { return ("Missing 'question'.", []) }
            guard let result = try? await deepSeek.answerWithConfidence([["role": "user", "content": question]]),
                  !result.answer.isEmpty else {
                return ("Couldn't get an answer right now.", [])
            }
            guard let conf = result.confidence else {
                return ("\(result.answer)\n\n_(Confidence signal unavailable for this response.)_", [])
            }
            let (band, advice) = ConfidenceBand.describe(conf)
            return ("\(result.answer)\n\n**Confidence: \(ConfidenceBand.percent(conf))% (\(band))** — \(advice).", [])

        case "extract_fields":
            guard let text = arg("text"), !text.isEmpty else { return ("Missing 'text'.", []) }
            guard let fieldsRaw = arg("fields"), !fieldsRaw.isEmpty else { return ("Missing 'fields' (comma-separated names).", []) }
            let fields = fieldsRaw.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !fields.isEmpty else { return ("No field names found in 'fields'.", []) }
            let prior = FieldExtractor.messages(text: text, fields: fields)
            // Prefer native JSON mode (response_format); fall back to the beta-prefix path.
            var json = (try? await deepSeek.completeJSONMode(prior: prior)).flatMap { $0 }
            if json == nil { json = (try? await deepSeek.completeJSON(prior: prior)).flatMap { $0 } }
            guard let json, let table = FieldExtractor.format(json: json, fields: fields) else {
                return ("Couldn't extract structured fields — the model returned no valid JSON.", [])
            }
            return ("```\n\(table)\n```", [])

        case "extract_action_items":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding action items in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let items = ActionItemExtractor.extract(text)
            guard !items.isEmpty else { return ("No action items found in '\(it.title)'.", []) }
            return ("\(items.count) action item(s) in '\(it.title)':\n" + items.map { "• \($0)" }.joined(separator: "\n"), [])

        case "entity_extract":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding people, orgs & places in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = EntityExtractor.summary(text) else {
                return ("No named entities (people, organizations, places) found in '\(it.title)'.", [])
            }
            return ("Entities in '\(it.title)':\n" + summary, [])

        case "sentiment":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Gauging the tone of \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = SentimentAnalyzer.summary(text) else {
                return ("Couldn't gauge sentiment for '\(it.title)' (no readable text).", [])
            }
            return ("Tone of '\(it.title)': " + summary, [])

        case "detect_language":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Detecting the language of \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = LanguageDetector.summary(text) else {
                return ("Couldn't detect a language for '\(it.title)' (too little text).", [])
            }
            return ("Language of '\(it.title)': " + summary, [])

        case "reading_time":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Measuring \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            return ("'\(it.title)' — \(ReadingTime.summary(text)).", [])

        case "readability":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Scoring the readability of \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = ReadabilityAnalyzer.summary(text) else {
                return ("Couldn't score '\(it.title)' (too short, or not English-oriented text — readability is English-based).", [])
            }
            return ("Readability of '\(it.title)': " + summary, [])

        default:
            return nil
        }
    }
}
