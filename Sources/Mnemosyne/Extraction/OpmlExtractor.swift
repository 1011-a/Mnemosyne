import Foundation

/// Turns an OPML file (`.opml` — RSS/podcast subscription exports, outliner
/// documents) into readable text: the document title, then each `<outline>`
/// node's label and feed URL. Uses `XMLParser` so XML entities decode correctly.
/// `parse` is unit-testable on raw `Data`.
enum OpmlExtractor {
    static func isOpml(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "opml"
    }

    static func extract(_ url: URL) throws -> String {
        parse(try Data(contentsOf: url))
    }

    static func parse(_ data: Data) -> String {
        let collector = OutlineCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.lines.joined(separator: "\n")
    }
}

private final class OutlineCollector: NSObject, XMLParserDelegate {
    var lines: [String] = []
    private var inTitle = false
    private var titleBuffer = ""

    func parser(_ parser: XMLParser, didStartElement element: String,
                namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
        switch element.lowercased() {
        case "title":
            inTitle = true; titleBuffer = ""
        case "outline":
            let label = (attrs["text"] ?? attrs["title"] ?? "").trimmingCharacters(in: .whitespaces)
            let feed = (attrs["xmlUrl"] ?? attrs["xmlurl"] ?? attrs["url"] ?? "").trimmingCharacters(in: .whitespaces)
            let line = [label, feed].filter { !$0.isEmpty }.joined(separator: " — ")
            if !line.isEmpty { lines.append(line) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTitle { titleBuffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement element: String,
                namespaceURI: String?, qualifiedName: String?) {
        if element.lowercased() == "title" {
            inTitle = false
            let t = titleBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.insert(t, at: 0) }   // document title leads
        }
    }
}
