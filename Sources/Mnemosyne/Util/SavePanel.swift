import AppKit
import UniformTypeIdentifiers

/// Thin wrapper over NSSavePanel for writing exported text to disk.
@MainActor
enum SavePanel {
    static func writeText(_ text: String, suggestedName: String, types: [UTType]) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.data(using: .utf8)?.write(to: url)
    }
}
