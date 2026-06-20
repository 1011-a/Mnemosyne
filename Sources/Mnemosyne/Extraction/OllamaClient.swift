import Foundation

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
        var req = URLRequest(url: config.ollamaBaseURL.appendingPathComponent("api/tags"))
        req.timeoutInterval = 3
        return (try? await session.data(for: req)) != nil
    }

    private struct GenerateResponse: Decodable { let response: String }
}
