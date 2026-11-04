import Foundation

/// A tolerant, strictly parsed JSON value. Config files are read into this type so unknown keys
/// survive and a wrong type becomes a `Problem` instead of a crash.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Strict parse: comments, trailing commas, a byte-order mark and other non-RFC 8259 syntax are rejected,
    /// matching what Claude Code (Node `JSON.parse`) accepts. Foundation's decoder alone is more lenient on Linux.
    public static func parse(_ data: Data) throws -> JSONValue {
        try StrictJSON.validate(data)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

public struct StrictJSONError: Error, Equatable, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "invalid JSON at byte \(offset): \(reason)" }
}

/// RFC 8259 syntax check over UTF-8 bytes. It validates only; `JSONDecoder` builds the value.
public enum StrictJSON {
    public static func validate(_ data: Data) throws {
        var scanner = Scanner(bytes: [UInt8](data))
        try scanner.document()
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 512

        mutating func document() throws {
            skipWhitespace()
            try value(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw fail("unexpected data after the value") }
        }

        func fail(_ reason: String) -> StrictJSONError { StrictJSONError(offset: index, reason: reason) }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        mutating func expect(_ byte: UInt8, _ what: String) throws {
            guard current == byte else { throw fail("expected \(what)") }
            index += 1
        }

        mutating func value(depth: Int) throws {
            guard depth < Self.maxDepth else { throw fail("nesting too deep") }
            guard let byte = current else { throw fail("unexpected end of input") }
            switch byte {
            case UInt8(ascii: "{"): try object(depth: depth)
            case UInt8(ascii: "["): try array(depth: depth)
            case UInt8(ascii: "\""): try string()
            case UInt8(ascii: "t"): try literal("true")
            case UInt8(ascii: "f"): try literal("false")
            case UInt8(ascii: "n"): try literal("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
            default: throw fail("unexpected character")
            }
        }

        mutating func object(depth: Int) throws {
            index += 1
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw fail("expected a string key") }
                try string()
                skipWhitespace()
                try expect(UInt8(ascii: ":"), "':'")
                skipWhitespace()
                try value(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "}"), "',' or '}'")
                return
            }
        }

        mutating func array(depth: Int) throws {
            index += 1
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return
            }
            while true {
                skipWhitespace()
                guard current != UInt8(ascii: "]") else { throw fail("trailing comma") }
                try value(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "]"), "',' or ']'")
                return
            }
        }

        mutating func string() throws {
            index += 1
            while let byte = current {
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    return
                case 0x00..<0x20:
                    throw fail("control character in string")
                case UInt8(ascii: "\\"):
                    index += 1
                    guard let escape = current else { throw fail("unterminated escape") }
                    if Array("\"\\/bfnrt".utf8).contains(escape) {
                        index += 1
                    } else if escape == UInt8(ascii: "u") {
                        index += 1
                        for _ in 0..<4 {
                            guard let hex = current, isHex(hex) else { throw fail("bad \\u escape") }
                            index += 1
                        }
                    } else {
                        throw fail("bad escape")
                    }
                default:
                    index += 1
                }
            }
            throw fail("unterminated string")
        }

        mutating func number() throws {
            if current == UInt8(ascii: "-") { index += 1 }
            guard let first = current, isDigit(first) else { throw fail("bad number") }
            if first == UInt8(ascii: "0") {
                index += 1
            } else {
                while let byte = current, isDigit(byte) { index += 1 }
            }
            if current == UInt8(ascii: ".") {
                index += 1
                guard let byte = current, isDigit(byte) else { throw fail("bad fraction") }
                while let byte = current, isDigit(byte) { index += 1 }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard let byte = current, isDigit(byte) else { throw fail("bad exponent") }
                while let byte = current, isDigit(byte) { index += 1 }
            }
        }

        mutating func literal(_ word: String) throws {
            for byte in word.utf8 {
                guard current == byte else { throw fail("expected \(word)") }
                index += 1
            }
        }

        func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }

        func isHex(_ byte: UInt8) -> Bool {
            isDigit(byte) || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F"))
        }
    }
}
