import Foundation
import PDFKit
import Vision
import AppKit
import ImageIO

/// Turns any supported file into plain text the embedder/agent can use.
/// - PDFs: native text per page; scanned/sparse pages are rendered and described by the selected vision engine.
/// - Images: Vision OCR (en+zh) plus a selected-engine visual description.
/// - rtf/html: flattened via NSAttributedString.
/// - everything else textual: decoded directly.
struct ContentExtractor: Sendable {
    let ollama: OllamaClient
    /// When false (Gemma unreachable), skip multimodal steps and degrade gracefully.
    let multimodal: Bool
    /// Which engine handles image / scanned-PDF understanding.
    var visionEngine: VisionEngine = .gemma

    /// Route a visual-understanding call to the selected engine. Returns nil when
    /// the engine is unavailable or fails, so callers degrade gracefully.
    private func describeVisual(_ pngData: Data, prompt: String) async -> String? {
        switch visionEngine {
        case .gemma:
            return try? await ollama.describeImage(pngData, prompt: prompt)
        case .claudeCode:
            return await ClaudeCodeClient.describe(pngData: pngData, prompt: prompt)
        case .codex:
            return await CodexCliClient.describe(pngData: pngData, prompt: prompt)
        }
    }

    private static let sparsePageThreshold = 40   // chars below which a PDF page is "scanned"
    private static let maxVisualPagesPerPDF = 15   // cap visual calls per document

    func extract(url: URL, kind: ItemKind) async throws -> String {
        switch kind {
        case .pdf:                       return try await extractPDF(url)
        case .image:                     return try await extractImage(url)
        case .richtext, .html, .wordDoc: return try await extractAttributed(url, kind: kind)
        case .audioTranscript:           return await AudioTranscriber.transcribe(url) ?? ""
        case .iwork:                     return try await extractIWork(url)
        case .email:                     return try EmailExtractor.extract(url)
        case .contact:                   return try VCardExtractor.extract(url)
        case .event:                     return try ICalExtractor.extract(url)
        case .webpage:                   return try WebLocExtractor.extract(url)
        default:                         return try extractPlain(url)
        }
    }

    // MARK: Plain text / code / markdown / data

    private func extractPlain(_ url: URL) throws -> String {
        // Subtitles arrive as `.text` but need their cues/timecodes stripped.
        if SubtitleExtractor.isSubtitle(url) { return try SubtitleExtractor.extract(url) }
        if OpmlExtractor.isOpml(url) { return try OpmlExtractor.extract(url) }
        if CsvExtractor.isCsv(url) { return try CsvExtractor.extract(url) }
        if JsonExtractor.isJson(url) { return try JsonExtractor.extract(url) }
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        let data = try Data(contentsOf: url)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: rtf / html

    private func extractAttributed(_ url: URL, kind: ItemKind) async throws -> String {
        let data = try Data(contentsOf: url)
        let docType: NSAttributedString.DocumentType
        switch kind {
        case .html:    docType = .html
        case .wordDoc: docType = (url.pathExtension.lowercased() == "doc") ? .docFormat : .officeOpenXML
        default:       docType = .rtf
        }
        // HTML parsing must run on the main actor (it can touch WebKit).
        return await MainActor.run {
            let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: docType]
            if let attr = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) {
                return attr.string
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    // MARK: PDF

    private func extractPDF(_ url: URL) async throws -> String {
        // With external CLI engines, let the model read the whole document — it
        // captures tables, figures and scanned pages holistically, better than
        // per-page native text. Fall back to the native path if unavailable/empty.
        if multimodal, let whole = await readWholeDocument(atPath: url.path), !whole.isEmpty {
            return whole
        }
        guard let doc = PDFDocument(url: url) else {
            throw ExtractError.unreadable(url.lastPathComponent)
        }
        var parts: [String] = []
        var visualPagesUsed = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count >= Self.sparsePageThreshold {
                parts.append("[page \(i + 1)]\n\(text)")
            } else if multimodal, visualPagesUsed < Self.maxVisualPagesPerPDF,
                      let png = Self.renderPNG(page) {
                if let desc = await describeVisual(
                    png, prompt: "this is a scanned document page; transcribe ALL text verbatim, preserving structure, and describe any figure or table"),
                   !desc.isEmpty {
                    parts.append("[page \(i + 1) · visual]\n\(desc)")
                }
                visualPagesUsed += 1
            }
        }
        return parts.joined(separator: "\n\n")
    }

    private func readWholeDocument(atPath path: String) async -> String? {
        switch visionEngine {
        case .gemma:
            return nil
        case .claudeCode:
            return await ClaudeCodeClient.readDocument(atPath: path)
        case .codex:
            return await CodexCliClient.readDocument(atPath: path)
        }
    }

    /// iWork bundles (.pages/.key/.numbers) embed a QuickLook PDF preview we can
    /// read text from — robust without parsing Apple's proprietary IWA format.
    private func extractIWork(_ url: URL) async throws -> String {
        let fm = FileManager.default
        let direct = [url.appendingPathComponent("QuickLook/Preview.pdf"),
                      url.appendingPathComponent("preview.pdf")]
        for pdf in direct where fm.fileExists(atPath: pdf.path) {
            return try await extractPDF(pdf)
        }
        let quicklook = url.appendingPathComponent("QuickLook")
        if let items = try? fm.contentsOfDirectory(at: quicklook, includingPropertiesForKeys: nil),
           let pdf = items.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            return try await extractPDF(pdf)
        }
        return ""
    }

    private static func renderPNG(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(1600 / max(bounds.width, 1), 1600 / max(bounds.height, 1))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        return pngData(from: image)
    }

    // MARK: Image

    private func extractImage(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        var pieces: [String] = []
        // OCR keeps the full-resolution image (text legibility matters).
        if let ocr = Self.ocr(data), !ocr.isEmpty { pieces.append("Transcribed text:\n\(ocr)") }
        if multimodal {
            // The vision model only needs a downscaled copy for a description — a
            // 5760×3600 screenshot makes it "pan & scan" into many crops (~2× slower)
            // with no benefit, so cap the long edge first.
            if let caption = await describeVisual(
                Self.downscaledForVision(data),
                prompt: "describe this image in detail and transcribe any visible text verbatim"),
               !caption.isEmpty {
                pieces.append("Visual description:\n\(caption)")
            }
        }
        if pieces.isEmpty { pieces.append(url.deletingPathExtension().lastPathComponent) }
        return pieces.joined(separator: "\n\n")
    }

    /// Downscale an image's long edge to `maxEdge` px (never upscaling) so the local
    /// vision model isn't forced to process needless pixels. Decoded at reduced size
    /// via ImageIO for low memory. Falls back to the original bytes on any failure.
    static func downscaledForVision(_ data: Data, maxEdge: Int = 1024) -> Data {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return data }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:]) ?? data
    }

    /// Vision text recognition (accurate, English + Simplified Chinese).
    static func ocr(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

enum ExtractError: Error, LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self { case .unreadable(let n): return "Could not read \(n)" }
    }
}
