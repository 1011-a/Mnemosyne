import Foundation
import UniformTypeIdentifiers

/// Maps a file to the `ItemKind` that decides which extractor runs.
/// Uses UTType conformance so it works on real types, not just extensions.
enum TypeDetector {
    /// Returns nil for things we intentionally skip (binaries, archives, video…).
    static func kind(for url: URL) -> ItemKind? {
        // Extension-driven types first (bundles, mail, vCards resolve poorly via
        // UTType — e.g. a .vcf conforms to public.text and would look like a note).
        if isIWork(url) { return .iwork }
        if isEmail(url) { return .email }
        if isVCard(url) { return .contact }
        if isICal(url) { return .event }
        if isWebLoc(url) { return .webpage }
        if OpmlExtractor.isOpml(url) { return .text }   // XML, but route to the OPML extractor

        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return classifyByExtension(url) }

        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if isWordDoc(url) { return .wordDoc }
        if type.conforms(to: .sourceCode) || type.conforms(to: .shellScript) { return .code }
        if type.conforms(to: .rtf) || type.conforms(to: .rtfd) { return .richtext }
        if type.conforms(to: .html) || type.conforms(to: .xml) { return .html }
        if type.conforms(to: .json) || type.conforms(to: .commaSeparatedText)
            || type.conforms(to: .tabSeparatedText) || type.conforms(to: .propertyList) { return .data }
        if isMarkdown(url) { return .markdown }
        if type.conforms(to: .plainText) || type.conforms(to: .text) { return .text }
        // Audio gets transcribed locally (Speech framework); video still skipped.
        if type.conforms(to: .audio) { return .audioTranscript }

        // Skip remaining media/binaries/archives — nothing textual to extract.
        if type.conforms(to: .audiovisualContent) || type.conforms(to: .movie)
            || type.conforms(to: .archive) || type.conforms(to: .executable) { return nil }

        return classifyByExtension(url)
    }

    private static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
    private static func isWordDoc(_ url: URL) -> Bool {
        ["docx", "doc"].contains(url.pathExtension.lowercased())
    }
    static func isVCard(_ url: URL) -> Bool {
        ["vcf", "vcard"].contains(url.pathExtension.lowercased())
    }
    static func isICal(_ url: URL) -> Bool {
        ["ics", "ical", "ifb", "icalendar"].contains(url.pathExtension.lowercased())
    }
    static func isWebLoc(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "webloc"
    }
    static func isIWork(_ url: URL) -> Bool {
        ["pages", "key", "numbers"].contains(url.pathExtension.lowercased())
    }
    private static func isEmail(_ url: URL) -> Bool {
        ["eml", "emlx"].contains(url.pathExtension.lowercased())
    }
    private static let audioExts: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "caf", "flac", "aac"]

    private static let codeExts: Set<String> = [
        "swift","py","js","ts","tsx","jsx","go","rs","rb","java","kt","c","cpp","cc","h","hpp",
        "m","mm","cs","php","sh","bash","zsh","sql","r","scala","lua","pl","yaml","yml","toml"
    ]

    private static func classifyByExtension(_ url: URL) -> ItemKind? {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return nil }
        if isMarkdown(url) { return .markdown }
        if isWordDoc(url) { return .wordDoc }
        if audioExts.contains(ext) { return .audioTranscript }
        if codeExts.contains(ext) { return .code }
        if ["txt","text","log","org","rst","srt","vtt","sbv"].contains(ext) { return .text }
        if ["csv","tsv","json","xml","plist"].contains(ext) { return .data }
        if ["rtf","rtfd"].contains(ext) { return .richtext }
        if ["html","htm"].contains(ext) { return .html }
        if ["pdf"].contains(ext) { return .pdf }
        if ["png","jpg","jpeg","gif","heic","tiff","bmp","webp"].contains(ext) { return .image }
        return nil
    }
}
