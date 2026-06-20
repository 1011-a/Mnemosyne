import Foundation

enum OllamaStatus: Equatable, Sendable {
    case unknown
    case offline
    case modelMissing(installed: [String])
    case ready

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var isReachable: Bool {
        switch self {
        case .unknown, .offline: return false
        case .modelMissing, .ready: return true
        }
    }

    func label(model: String) -> String {
        switch self {
        case .unknown:
            return "Checking Ollama · \(model)"
        case .offline:
            return "Ollama not running · start it before ingest"
        case .modelMissing:
            return "\(model) missing · pull it before ingest"
        case .ready:
            return "\(model) ready for images & PDFs"
        }
    }

    func detail(model: String, baseURL: URL) -> String {
        switch self {
        case .unknown:
            return "Checking \(baseURL.absoluteString)…"
        case .offline:
            return "Start Ollama, then run `ollama pull \(model)` if the model is not installed."
        case .modelMissing(let installed):
            let shown = installed.prefix(3).joined(separator: ", ")
            let suffix = installed.count > 3 ? ", …" : ""
            let installedText = installed.isEmpty ? "No local Ollama models were reported." : "Installed: \(shown)\(suffix)."
            return "\(installedText) Run `ollama pull \(model)`."
        case .ready:
            return "Ollama is reachable at \(baseURL.absoluteString) and has the required model."
        }
    }
}

/// Local multimodal understanding via Ollama (gemma3:12b). Used to caption
/// images and describe/transcribe PDF page renders during ingestion, so the
/// agent brain (DeepSeek) can reason over visual content as text.
struct OllamaClient: Sendable {
    let config: Config
    private let session = URLSession(configuration: .default)

    init(config: Config) { self.config = config }

    /// Describe an image. `imageData` is raw bytes (PNG/JPEG); sent base64 to Gemma.
    func describeImage(_ imageData: Data,
                       prompt: String = "Describe this image in detail. Transcribe any visible text verbatim.")
        async throws -> String
    {
        try await generate(prompt: prompt, images: [imageData.base64EncodedString()])
    }

    /// Plain text generation (no images).
    func generateText(_ prompt: String) async throws -> String {
        try await generate(prompt: prompt, images: [])
    }

    private func generate(prompt: String, images: [String]) async throws -> String {
        var req = URLRequest(url: config.ollamaBaseURL.appendingPathComponent("api/generate"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        var body: [String: Any] = [
            "model": config.ollamaVisionModel,
            "prompt": prompt,
            "stream": false
        ]
        if !images.isEmpty { body["images"] = images }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let parsed = try JSONDecoder().decode(GenerateResponse.self, from: data)
        return parsed.response
    }

    /// True if the local Ollama server answers.
    func isReachable() async -> Bool {
        await status().isReachable
    }

    /// Full readiness check: Ollama must answer and the configured model must be installed.
    func status() async -> OllamaStatus {
        do {
            let models = try await installedModels()
            return Self.hasModel(config.ollamaVisionModel, in: models)
                ? .ready
                : .modelMissing(installed: models)
        } catch {
            return .offline
        }
    }

    private func installedModels() async throws -> [String] {
        var req = URLRequest(url: config.ollamaBaseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try Self.modelNames(fromTagsData: data)
    }

    static func modelNames(fromTagsData data: Data) throws -> [String] {
        let parsed = try JSONDecoder().decode(TagsResponse.self, from: data)
        var seen = Set<String>()
        var out: [String] = []
        for model in parsed.models {
            for name in [model.name, model.model].compactMap({ $0 }) {
                if seen.insert(name).inserted { out.append(name) }
            }
        }
        return out
    }

    static func hasModel(_ requested: String, in installed: [String]) -> Bool {
        let wanted = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return false }
        let aliases = wanted.contains(":") ? [wanted] : [wanted, "\(wanted):latest"]
        let normalized = Set(installed.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        return aliases.contains { normalized.contains($0) }
    }

    private struct GenerateResponse: Decodable { let response: String }
    private struct TagsResponse: Decodable {
        let models: [ModelTag]
    }
    private struct ModelTag: Decodable {
        let name: String?
        let model: String?
    }
}
