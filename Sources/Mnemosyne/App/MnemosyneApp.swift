import SwiftUI

extension Notification.Name {
    static let mnemoNewChat = Notification.Name("mnemo.newChat")
    static let mnemoSelectSection = Notification.Name("mnemo.selectSection")
    static let mnemoFocusSearch = Notification.Name("mnemo.focusSearch")
}

@main
struct MnemosyneApp: App {
    var body: some Scene {
        WindowGroup {
            ContentRoot()
        }
        // Use the NATIVE title bar (not .hiddenTitleBar): macOS then handles dragging,
        // double-click-to-zoom, and the green/zoom button itself — no custom code.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Native menu items (discoverable in the menu bar) that drive the
            // shell via NotificationCenter — see AppShell's listeners.
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    NotificationCenter.default.post(name: .mnemoNewChat, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find in Library") {
                    NotificationCenter.default.post(name: .mnemoFocusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Go") {
                sectionButton("Chat", "chat", "1")
                sectionButton("Library", "library", "2")
                sectionButton("Ingest", "ingest", "3")
                sectionButton("Insights", "insights", "4")
                sectionButton("Settings", "settings", "5")
            }
        }
    }

    private func sectionButton(_ title: String, _ id: String, _ key: KeyEquivalent) -> some View {
        Button(title) {
            NotificationCenter.default.post(name: .mnemoSelectSection, object: nil,
                                            userInfo: ["section": id])
        }
        .keyboardShortcut(key, modifiers: .command)
    }
}
