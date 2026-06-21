import Foundation
import NaturalLanguage

/// On-device NAMED-ENTITY recognition for the `entity_extract` tool — pulls the people,
/// organizations, and places mentioned in a document so the agent can answer "who/what
/// is mentioned here" or build contact/topic lists. Uses Apple's native `NLTagger`
/// (zero-dependency, private, offline) — same framework family as the embedder.
/// Deterministic for a given input → unit-testable. Distinct names, document order.
enum EntityExtractor {
    enum Kind: String, Sendable { case person, organization, place }

    static func extract(_ text: String, max: Int = 40) -> [(name: String, kind: Kind)] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]

        var out: [(name: String, kind: Kind)] = []
        var seen = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .nameType, options: options) { tag, range in
            let kind: Kind?
            switch tag {
            case .personalName:     kind = .person
            case .organizationName: kind = .organization
            case .placeName:        kind = .place
            default:                kind = nil
            }
            guard let kind else { return true }
            let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = kind.rawValue + ":" + name.lowercased()
            if name.count >= 2, seen.insert(key).inserted {
                out.append((name, kind))
                if out.count >= max { return false }
            }
            return true
        }
        return out
    }

    /// Group extracted entities into "People / Organizations / Places" lines for a tool
    /// reply. Returns nil when nothing was found.
    static func summary(_ text: String, max: Int = 40) -> String? {
        let entities = extract(text, max: max)
        guard !entities.isEmpty else { return nil }
        func line(_ label: String, _ kind: Kind) -> String? {
            let names = entities.filter { $0.kind == kind }.map(\.name)
            return names.isEmpty ? nil : "\(label): " + names.joined(separator: ", ")
        }
        return [line("People", .person), line("Organizations", .organization), line("Places", .place)]
            .compactMap { $0 }.joined(separator: "\n")
    }
}
