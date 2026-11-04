import Foundation

/// Masks secrets before any value reaches a result object, a log or the UI (NFR-SEC).
public enum Redactor {
    public static let mask = "••••••"
    /// Used inside URLs, where the bullet characters would be percent-encoded.
    public static let urlMask = "REDACTED"

    private static let secretMarkers = [
        "token", "secret", "password", "passwd", "apikey", "api_key", "api-key", "authorization",
        "bearer", "credential", "cookie", "privatekey", "private_key", "private-key",
    ]

    public static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return secretMarkers.contains { lower.contains($0) }
    }

    /// Masks user info and secret-looking query parameters. Returns the input when it is not a URL.
    public static func maskURL(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), components.scheme != nil, components.host != nil else {
            return raw
        }
        if components.user != nil { components.user = urlMask }
        if components.password != nil { components.password = urlMask }
        if let items = components.queryItems {
            components.queryItems = items.map { isSecretKey($0.name) ? URLQueryItem(name: $0.name, value: urlMask) : $0 }
        }
        return components.string ?? raw
    }

    /// Deep copy with `env` and `headers` maps fully masked (names kept), secret-looking string values
    /// masked, and URLs under `*url` / `*endpoint` keys passed through `maskURL`.
    public static func redact(_ value: JSONValue, parentKey: String = "") -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map { redact($0, parentKey: parentKey) })
        case .object(let object):
            var out: [String: JSONValue] = [:]
            for (key, child) in object {
                if key == "env" || key == "headers", let map = child.objectValue {
                    out[key] = .object(map.mapValues { _ in .string(mask) })
                } else if isSecretKey(key), case .string = child {
                    out[key] = .string(mask)
                } else {
                    out[key] = redact(child, parentKey: key)
                }
            }
            return .object(out)
        case .string(let text):
            let lowerKey = parentKey.lowercased()
            let lowerText = text.lowercased()
            if (lowerKey.hasSuffix("url") || lowerKey.hasSuffix("endpoint"))
                && (lowerText.hasPrefix("http://") || lowerText.hasPrefix("https://"))
            {
                return .string(maskURL(text))
            }
            return value
        case .null, .bool, .number:
            return value
        }
    }
}
