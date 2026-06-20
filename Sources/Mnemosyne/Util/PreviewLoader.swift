import AppKit

/// Renders a small visual preview (PNG bytes) for an item's source file.
/// Covers the visual kinds — images and PDFs (NSImage renders a PDF's first
/// page). Returns nil for non-visual kinds or unreadable files.
enum PreviewLoader {
    static func previewPNG(for url: URL, kind: ItemKind, maxDimension: CGFloat = 480) -> Data? {
        guard kind == .image || kind == .pdf else { return nil }
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return nil }
        let scaled = downscale(image, maxDimension: maxDimension)
        guard let tiff = scaled.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private static func downscale(_ image: NSImage, maxDimension: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension,
              size.width > 0, size.height > 0 else { return image }
        let scale = maxDimension / max(size.width, size.height)
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let out = NSImage(size: target)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
