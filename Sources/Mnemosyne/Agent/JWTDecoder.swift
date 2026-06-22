import Foundation

/// Decodes a JSON Web Token's header and payload for the `jwt_decode` tool — inspect what an auth
/// token actually claims (issuer, subject, expiry, scopes) without needing the signing key. It
/// does NOT verify the signature (that needs the secret); it's a decoder, not a validator. Pure +
/// deterministic → unit-testable.
enum JWTDecoder {
    struct Decoded: Equatable { let header: String; let payload: String }

    /// Decode the header + payload of a `header.payload.signature` JWT. nil if it doesn't have
    /// three parts or a segment isn't valid base64url-encoded UTF-8.
    static func decode(_ token: String) -> Decoded? {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let header = decodeSegment(String(parts[0])),
              let payload = decodeSegment(String(parts[1])) else { return nil }
        return Decoded(header: header, payload: payload)
    }

    /// Base64url-decode one segment to its UTF-8 string (adds padding, maps -/_ → +//).
    static func decodeSegment(_ seg: String) -> String? {
        guard !seg.isEmpty else { return nil }
        var s = seg.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: s),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Pretty-print a JSON string (stable key order); returns the input unchanged if it isn't JSON.
    static func prettify(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                       options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8) else { return json }
        return str
    }
}
