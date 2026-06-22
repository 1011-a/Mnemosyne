import AppKit
import WebKit

/// Renders an HTML artifact's main page to a thumbnail image and caches it to disk
/// (`.thumbnail.png` inside the artifact folder), so the gallery shows real previews
/// instead of icons. Renders once, then serves the cached PNG. Returns nil on any
/// failure (→ the gallery shows an icon). Uses an offscreen window for reliable
/// WKWebView snapshotting.
@MainActor
final class ArtifactThumbnailer {
    static let shared = ArtifactThumbnailer()
    private var live = Set<Renderer>()

    func thumbnail(for artifact: Artifact) async -> NSImage? {
        guard let main = artifact.mainPath, main.lowercased().hasSuffix(".html") else { return nil }
        let cache = artifact.path + "/.thumbnail.png"
        if FileManager.default.fileExists(atPath: cache), let img = NSImage(contentsOfFile: cache) { return img }
        guard let img = await render(htmlPath: main, base: artifact.path) else { return nil }
        if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: cache))
        }
        return img
    }

    private func render(htmlPath: String, base: String) async -> NSImage? {
        await withCheckedContinuation { cont in
            let r = Renderer()
            live.insert(r)
            r.render(htmlPath: htmlPath, base: base) { [weak self] img in
                self?.live.remove(r)
                cont.resume(returning: img)
            }
        }
    }
}

/// One-shot WKWebView render of a local HTML file to an NSImage.
@MainActor
private final class Renderer: NSObject, WKNavigationDelegate {
    private var web: WKWebView?
    private var window: NSWindow?
    private var done: ((NSImage?) -> Void)?
    private let size = CGSize(width: 1200, height: 820)

    func render(htmlPath: String, base: String, completion: @escaping (NSImage?) -> Void) {
        done = completion
        let w = WKWebView(frame: CGRect(origin: .zero, size: size))
        w.navigationDelegate = self
        // An offscreen window keeps the view in the window server so snapshots aren't blank.
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = w
        win.orderBack(nil)
        web = w; window = win
        w.loadFileURL(URL(fileURLWithPath: htmlPath), allowingReadAccessTo: URL(fileURLWithPath: base))
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.finish(nil) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.done != nil else { return }
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(origin: .zero, size: self.size)
            webView.takeSnapshot(with: cfg) { img, _ in self.finish(img) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }

    private func finish(_ img: NSImage?) {
        guard let d = done else { return }
        done = nil; window?.orderOut(nil); window = nil; web = nil
        d(img)
    }
}
