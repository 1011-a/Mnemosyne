import Foundation

/// Translation tool handlers (free text / a stored item), extracted from `ToolAgent`'s main
/// `handleTool` switch to keep that file focused. LLM-coupled — both drive DeepSeek with the shared
/// translate prompt — so they live in an `extension ToolAgent` (access to `deepSeek`, `store`,
/// `resolveItems`) rather than migrating to Fathom. `handleTranslateTool` returns nil when `name`
/// isn't one of these, letting the caller fall through.
extension ToolAgent {
    func handleTranslateTool(_ name: String, args: String,
                             onStatus: @Sendable @escaping (String) -> Void) async -> (String, [Citation])? {
        func arg(_ k: String) -> String? { Self.stringArg(args, k) }
        switch name {
        case "translate":
            guard let text = arg("text")?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let to = arg("to")?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty
            else { return ("Missing 'text' or 'to'.", []) }
            onStatus("Translating to \(to)…")
            let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                       "messages": [["role": "system", "content": Self.translatePrompt(to: to)],
                                                    ["role": "user", "content": text]],
                                       "temperature": SamplingPreset.temperature(for: .translation), "tool_choice": "none"]
            guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
                  let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let translated = resp.choices.first?.message.content, !translated.isEmpty else {
                return ("Couldn't translate that right now.", [])
            }
            return ("Translation (\(to)):\n\(translated)", [])

        case "translate_item":
            guard let ref = arg("item"),
                  let to = arg("to")?.trimmingCharacters(in: .whitespacesAndNewlines), !to.isEmpty
            else { return ("Missing 'item' or 'to'.", []) }
            let matches = await resolveItems(ref)
            guard matches.count == 1, let it = matches.first else { return (Self.ambiguity(matches, ref: ref), []) }
            onStatus("Translating \(it.title) to \(to)…")
            let text = String(((try? await store.chunkTexts(forItem: it.id)) ?? []).joined(separator: "\n").prefix(6000))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ("'\(it.title)' has no readable text to translate.", [])
            }
            let body: [String: Any] = ["model": deepSeek.config.deepSeekModel,
                                       "messages": [["role": "system", "content": Self.translatePrompt(to: to)],
                                                    ["role": "user", "content": text]],
                                       "temperature": SamplingPreset.temperature(for: .translation), "tool_choice": "none"]
            guard let data = try? await deepSeek.rawChat(body: JSONSerialization.data(withJSONObject: body)),
                  let resp = try? JSONDecoder().decode(ChatResponse.self, from: data),
                  let translated = resp.choices.first?.message.content, !translated.isEmpty else {
                return ("Couldn't translate '\(it.title)' right now.", [])
            }
            return ("'\(it.title)' translated to \(to):\n\(translated)", [])

        default:
            return nil
        }
    }
}
