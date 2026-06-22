import SwiftUI
import AppKit

/// A single-line text field that handles input-method (Chinese / Japanese / Korean)
/// composition CORRECTLY.
///
/// The problem with SwiftUI's `TextField(...).onSubmit`: while an IME is composing a
/// candidate (e.g. typing pinyin and pressing Return to PICK a Chinese character),
/// SwiftUI fires `onSubmit` on that Return — sending and clearing the field mid-
/// composition, so you can never actually commit Chinese.
///
/// AppKit's `NSTextField` field editor exposes `hasMarkedText()` (true while the IME is
/// composing). So we drop to AppKit and intercept Return: if the IME is composing, let it
/// confirm the candidate; only a Return with NO marked text sends. This is the native,
/// IME-aware behavior SwiftUI doesn't give us.
struct IMETextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    /// Bump to programmatically focus the field (e.g. ⌘K).
    var focusRequest: Int
    var onSubmit: () -> Void
    var onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.delegate = context.coordinator
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 15)
        tf.textColor = .labelColor
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        tf.allowsEditingTextAttributes = false
        return tf
    }

    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self            // keep closures/binding current
        if tf.stringValue != text { tf.stringValue = text }
        tf.placeholderString = placeholder
        // Programmatic focus when the request token changes.
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak tf] in
                guard let tf, let window = tf.window else { return }
                window.makeFirstResponder(tf)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: IMETextField
        var lastFocusRequest: Int
        init(_ parent: IMETextField) { self.parent = parent; self.lastFocusRequest = parent.focusRequest }

        func controlTextDidChange(_ note: Notification) {
            guard let tf = note.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }
        func controlTextDidBeginEditing(_ note: Notification) { parent.onFocusChange(true) }
        func controlTextDidEndEditing(_ note: Notification) { parent.onFocusChange(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
            // IME is composing a candidate → let Return confirm it, don't send.
            if textView.hasMarkedText() { return false }
            parent.onSubmit()
            return true   // consumed: keep focus, no newline inserted
        }
    }
}
