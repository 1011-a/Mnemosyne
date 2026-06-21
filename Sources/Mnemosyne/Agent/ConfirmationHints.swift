import Foundation

/// Detects when the agent's last answer is asking the user to CONFIRM a previewed
/// destructive/bulk action (the safe two-step flow: preview → approve). Drives the
/// one-tap Approve/Skip buttons so the user needn't type "apply"/"是". Pure → testable.
enum ConfirmationHints {
    static func isPendingConfirmation(_ text: String) -> Bool {
        let t = text.lowercased()
        // Raw tool-preview markers.
        if t.contains("apply=true") || t.contains("confirm=true") || t.contains("confirm needed")
            || t.contains("call again with") { return true }
        // The model often rephrases ("…to confirm, or 'no' to skip"); require a
        // confirm cue paired with an apply/yes/是/skip cue to avoid false positives.
        if t.contains("shall i apply") || t.contains("shall i go ahead") { return true }
        if (t.contains("to confirm") || t.contains("confirm?") || t.contains("proceed?")),
           t.contains("apply") || t.contains("yes") || t.contains("是") || t.contains("skip") || t.contains("no") {
            return true
        }
        return false
    }

    /// The message sent when the user taps Approve — spells out both param names so
    /// whichever confirm-gated tool is pending re-runs in apply mode.
    static let approveMessage = "Yes — go ahead and apply it now (apply=true, confirm=true)."
    static let skipMessage = "No, skip that — don't apply it."
}
