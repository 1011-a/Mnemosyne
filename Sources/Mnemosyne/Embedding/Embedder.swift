import Foundation
import NaturalLanguage

/// Local, zero-dependency text embeddings via Apple's `NLEmbedding`.
/// Sentence embeddings when available; otherwise a mean of word vectors.
/// All vectors are L2-normalized so cosine similarity == dot product.
// NLEmbedding is immutable and safe for concurrent reads, but isn't marked
// Sendable by the SDK — vouch for it.
struct Embedder: @unchecked Sendable {
    private let sentence: NLEmbedding?
    private let word: NLEmbedding?
    let dimension: Int

    init(language: NLLanguage = .english) {
        let s = NLEmbedding.sentenceEmbedding(for: language)
        let w = NLEmbedding.wordEmbedding(for: language)
        self.sentence = s
        self.word = w
        self.dimension = s?.dimension ?? w?.dimension ?? 0
    }

    var isAvailable: Bool { sentence != nil || word != nil }

    /// Embed a single chunk of text into an L2-normalized vector.
    func embed(_ text: String) -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let s = sentence, let v = s.vector(for: trimmed) {
            return Self.normalize(v.map(Float.init))
        }
        // Fallback: average word vectors over the tokenized text.
        guard let w = word else { return [] }
        var acc = [Double](repeating: 0, count: w.dimension)
        var n = 0
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = trimmed
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let token = String(trimmed[range]).lowercased()
            if let v = w.vector(for: token) {
                for i in 0..<acc.count { acc[i] += v[i] }
                n += 1
            }
            return true
        }
        guard n > 0 else { return [] }
        return Self.normalize(acc.map { Float($0 / Double(n)) })
    }

    static func normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine similarity for already-normalized vectors (== dot product).
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i] }
        return dot
    }
}
