import Foundation

/// Content-extraction tool handlers — pull quotes, links, dates, contacts, code blocks, tables, and
/// the like out of a stored item — extracted from `ToolAgent`'s main `handleTool` switch to keep that
/// file focused. Each resolves an item, reads its chunk text, then runs a pure extractor
/// (QuoteExtractor, LinkExtractor, DateExtractor, …). Store-coupled by the resolve+read step, so they
/// live in an `extension ToolAgent` rather than migrating to Fathom. `handleExtractionTool` returns
/// nil when `name` isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleExtractionTool(_ name: String, args: String,
                              onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "extract_quotes":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding quotes in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = QuoteExtractor.summary(full) else {
                return ("No quoted passages found in '\(it.title)'.", [])
            }
            return ("Quotes in '\(it.title)':\n\(summary)", [])

        case "extract_ips":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding IP addresses in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = IPExtractor.summary(full) else {
                return ("No IPv4 addresses found in '\(it.title)'.", [])
            }
            return ("IPs in '\(it.title)':\n\(summary)", [])

        case "extract_domains":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding domains in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = DomainExtractor.summary(full) else {
                return ("No domains (URLs/emails) found in '\(it.title)'.", [])
            }
            return ("Domains in '\(it.title)':\n\(summary)", [])

        case "extract_times":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding times in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = TimeExtractor.summary(full) else {
                return ("No times of day found in '\(it.title)'.", [])
            }
            return ("Times in '\(it.title)':\n\(summary)", [])

        case "extract_percentages":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding percentages in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = PercentExtractor.summary(full) else {
                return ("No percentages found in '\(it.title)'.", [])
            }
            return ("Percentages in '\(it.title)':\n\(summary)", [])

        case "read_frontmatter":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Reading frontmatter in \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = Frontmatter.summary(full) else {
                return ("'\(it.title)' has no frontmatter (a leading '---' metadata block).", [])
            }
            return ("'\(it.title)':\n\(summary)", [])

        case "keyword_extract":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Extracting key terms from \(it.title)…")
            let full = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            return ("Top terms in '\(it.title)': \(KeywordExtractor.summary(full))", [])

        case "extract_links":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding links in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let links = LinkExtractor.extract(text)
            guard !links.isEmpty else { return ("No web links found in '\(it.title)'.", []) }
            return ("\(links.count) link(s) in '\(it.title)':\n" + links.map { "• \($0)" }.joined(separator: "\n"), [])

        case "extract_dates":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding dates in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let dates = DateExtractor.extract(text)
            guard !dates.isEmpty else { return ("No dates found in '\(it.title)'.", []) }
            return ("\(dates.count) date(s) in '\(it.title)': " + dates.joined(separator: "; "), [])

        case "timeline":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Building a timeline for \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let ordered = DateExtractor.chronological(text)
            guard !ordered.isEmpty else { return ("No dates to build a timeline from in '\(it.title)'.", []) }
            return ("Timeline of '\(it.title)' (earliest → latest):\n" +
                    ordered.map { "• \($0)" }.joined(separator: "\n"), [])

        case "extract_emails":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding emails in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let emails = EmailAddressExtractor.extract(text)
            guard !emails.isEmpty else { return ("No email addresses found in '\(it.title)'.", []) }
            return ("\(emails.count) email(s) in '\(it.title)': " + emails.joined(separator: ", "), [])

        case "extract_phone_numbers":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding phone numbers in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let phones = PhoneExtractor.extract(text)
            guard !phones.isEmpty else { return ("No phone numbers found in '\(it.title)'.", []) }
            return ("\(phones.count) phone number(s) in '\(it.title)': " + phones.joined(separator: ", "), [])

        case "extract_contacts":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Rounding up contacts in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let people = EntityExtractor.extract(text).filter { $0.kind == .person }.map(\.name)
            let emails = EmailAddressExtractor.extract(text)
            let phones = PhoneExtractor.extract(text)
            guard let rollup = ContactRollup.format(people: people, emails: emails, phones: phones) else {
                return ("No contacts (people, emails, or phone numbers) found in '\(it.title)'.", [])
            }
            return ("Contacts in '\(it.title)':\n" + rollup, [])

        case "extract_figures":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding amounts & percentages in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = FigureExtractor.summary(text) else {
                return ("No monetary amounts or percentages found in '\(it.title)'.", [])
            }
            return ("Figures in '\(it.title)':\n" + summary, [])

        case "extract_questions":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding questions in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            let questions = QuestionExtractor.extract(text)
            guard !questions.isEmpty else { return ("No questions found in '\(it.title)'.", []) }
            return ("\(questions.count) question(s) in '\(it.title)':\n" + questions.map { "• \($0)" }.joined(separator: "\n"), [])

        case "extract_acronyms":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding acronyms in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = AcronymExtractor.summary(text) else {
                return ("No acronyms found in '\(it.title)'.", [])
            }
            return ("Acronyms in '\(it.title)': \(summary)", [])

        case "extract_code_blocks":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding code snippets in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = CodeBlockExtractor.summary(text) else {
                return ("No fenced code blocks found in '\(it.title)'.", [])
            }
            return ("Code in '\(it.title)':\n\(summary)", [])

        case "extract_tables":
            guard let ref = arg("item") else { return ("Missing 'item'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Finding tables in \(it.title)…")
            let text = ((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n")
            guard let summary = TableExtractor.summary(text) else {
                return ("No markdown tables found in '\(it.title)'.", [])
            }
            return ("Tables in '\(it.title)':\n\(summary)", [])

        default:
            return nil
        }
    }
}
