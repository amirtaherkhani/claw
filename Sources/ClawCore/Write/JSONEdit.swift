import Foundation

/// One step of a path into a JSON document.
public enum JSONPathComponent: Sendable, Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    public init(stringLiteral value: String) { self = .key(value) }
    public init(integerLiteral value: Int) { self = .index(value) }
}

public struct JSONEditError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

/// Minimal edits of strict JSON text (TECHNICAL-DESIGN section 9.1). Each edit replaces one byte range, so keys
/// the app does not know, key order, indentation and line endings all stay as the user wrote them.
public enum JSONEdit {
    /// Sets one value and creates missing objects on the way. Setting the value already there changes nothing.
    public static func set(_ data: Data, path: [JSONPathComponent], value: JSONValue) throws -> Data {
        guard !path.isEmpty else { throw JSONEditError(reason: "a path is required") }
        let document = try JSONDocument(data)
        let walk = try document.walk(path)
        guard walk.chain.count > path.count else {
            return try document.addMissing(path: path, walk: walk, value: value)
        }
        let target = walk.chain[path.count]
        if try JSONValue.parse(Data(document.bytes[target.start..<target.end])) == value { return data }
        let parent = walk.chain[path.count - 1]
        let text = try document.write(value, indent: document.lineIndent(target.start), inline: document.isInline(parent))
        return try document.splice(target.start..<target.end, text)
    }

    /// Removes a key or an array element. Removing something absent changes nothing.
    public static func remove(_ data: Data, path: [JSONPathComponent]) throws -> Data {
        guard !path.isEmpty else { throw JSONEditError(reason: "a path is required") }
        let document = try JSONDocument(data)
        let walk = try document.walk(path, missingIsAllowed: true)
        guard walk.chain.count > path.count else { return data }
        let parent = walk.chain[path.count - 1]
        let spans = parent.childSpans
        guard let position = parent.position(of: path[path.count - 1]) else { return data }
        guard spans.count > 1 else { return try document.splice((parent.start + 1)..<(parent.end - 1), []) }
        if position + 1 < spans.count {
            return try document.splice(spans[position].lowerBound..<spans[position + 1].lowerBound, [])
        }
        return try document.splice(spans[position - 1].upperBound..<spans[position].upperBound, [])
    }

    /// The bytes of the value at `path` as written, or `nil` when it is absent.
    public static func text(_ data: Data, path: [JSONPathComponent]) throws -> Data? {
        let document = try JSONDocument(data)
        let walk = try document.walk(path, missingIsAllowed: true)
        guard walk.chain.count > path.count else { return nil }
        let node = walk.chain[path.count]
        return Data(document.bytes[node.start..<node.end])
    }

    /// Inserts into the array at `path`, at the end when `index` is `nil`. A missing array is created. `raw`, when
    /// given, is `value` as it was once written, used so a restored value keeps its key order and spacing.
    public static func insert(
        _ data: Data, arrayAt path: [JSONPathComponent], index: Int? = nil, value: JSONValue, raw: Data? = nil
    ) throws -> Data {
        let document = try JSONDocument(data)
        let walk = try document.walk(path)
        guard walk.chain.count > path.count else {
            guard index ?? 0 == 0 else { throw JSONEditError(reason: "index out of range") }
            return try document.addMissing(path: path, walk: walk, value: .array([value]))
        }
        let array = walk.chain[path.count]
        guard case .array(let elements) = array.kind else { throw JSONEditError(reason: "not an array") }
        let position = index ?? elements.count
        guard (0...elements.count).contains(position) else { throw JSONEditError(reason: "index out of range") }
        if elements.isEmpty {
            return try document.fillEmpty(
                array, ancestors: walk.chain.dropLast(),
                member: { indent, inline in
                    try raw.map { [UInt8]($0) } ?? document.write(value, indent: indent, inline: inline)
                })
        }
        let inline = document.isInline(array)
        let separator = document.separator(after: array)
        if position == elements.count {
            let last = elements[position - 1]
            let indent = document.lineIndent(last.start)
            let text = try raw.map { [UInt8]($0) } ?? document.write(value, indent: indent, inline: inline)
            let gap = inline ? separator : document.eol + Array(indent)
            return try document.splice(last.end..<last.end, [comma] + gap + text)
        }
        let next = elements[position]
        let indent = document.lineIndent(next.start)
        let text = try raw.map { [UInt8]($0) } ?? document.write(value, indent: indent, inline: inline)
        let gap = inline ? separator : document.eol + Array(indent)
        return try document.splice(next.start..<next.start, text + [comma] + gap)
    }
}

private let comma = UInt8(ascii: ",")

/// A byte range in the text, with its children. The input is already validated, so parsing needs no error paths.
private struct JSONNode {
    struct Member {
        let key: String
        let keyStart: Int
        let keyEnd: Int
        let value: JSONNode
    }

    indirect enum Kind {
        case scalar
        case object([Member])
        case array([JSONNode])
    }

    let start: Int
    let end: Int
    let kind: Kind

    var childSpans: [Range<Int>] {
        switch kind {
        case .scalar: []
        case .object(let members): members.map { $0.keyStart..<$0.value.end }
        case .array(let elements): elements.map { $0.start..<$0.end }
        }
    }

    func position(of component: JSONPathComponent) -> Int? {
        switch (kind, component) {
        case (.object(let members), .key(let key)): members.firstIndex { $0.key == key }
        case (.array(let elements), .index(let index)): elements.indices.contains(index) ? index : nil
        default: nil
        }
    }
}

private struct JSONDocument {
    struct Walk {
        /// The root, then one node for each path step that exists.
        var chain: [JSONNode]
    }

    let bytes: [UInt8]
    let root: JSONNode
    let unit: [UInt8]
    let eol: [UInt8]

    init(_ data: Data) throws {
        do {
            try StrictJSON.validate(data)
        } catch {
            throw JSONEditError(reason: "invalid JSON: \(error)")
        }
        bytes = [UInt8](data)
        var parser = Parser(bytes: bytes)
        root = try parser.document()
        unit = Self.detectUnit(bytes)
        eol = Self.detectEol(bytes)
    }

    private static func detectEol(_ bytes: [UInt8]) -> [UInt8] {
        guard let line = bytes.firstIndex(of: 0x0A), line > 0, bytes[line - 1] == 0x0D else { return [0x0A] }
        return [0x0D, 0x0A]
    }

    /// The first indented key gives the unit; two spaces when nothing is indented.
    private static func detectUnit(_ bytes: [UInt8]) -> [UInt8] {
        var index = 0
        while let newline = bytes[index...].firstIndex(of: 0x0A) {
            var cursor = newline + 1
            while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
            if cursor > newline + 1, cursor < bytes.count, bytes[cursor] == UInt8(ascii: "\"") {
                return bytes[newline + 1] == 0x09 ? [0x09] : Array(bytes[(newline + 1)..<cursor])
            }
            index = newline + 1
        }
        return [0x20, 0x20]
    }

    func walk(_ path: [JSONPathComponent], missingIsAllowed: Bool = false) throws -> Walk {
        var chain = [root]
        for component in path {
            let node = chain[chain.count - 1]
            switch (node.kind, component) {
            case (.object(let members), .key(let key)):
                let found = members.filter { $0.key == key }
                guard found.count < 2 else { throw JSONEditError(reason: "duplicate key \(key)") }
                guard let member = found.first else { return Walk(chain: chain) }
                chain.append(member.value)
            case (.array(let elements), .index(let index)):
                guard elements.indices.contains(index) else {
                    if missingIsAllowed { return Walk(chain: chain) }
                    throw JSONEditError(reason: "index out of range")
                }
                chain.append(elements[index])
            default:
                throw JSONEditError(reason: "the path does not match the document")
            }
        }
        return Walk(chain: chain)
    }

    /// Adds what `walk` did not find: the first missing key, holding the rest of the path.
    func addMissing(path: [JSONPathComponent], walk: Walk, value: JSONValue) throws -> Data {
        let found = walk.chain.count - 1
        var wrapped = value
        for component in path[(found + 1)...].reversed() {
            guard case .key(let key) = component else { throw JSONEditError(reason: "index out of range") }
            wrapped = .object([key: wrapped])
        }
        guard case .key(let key) = path[found] else { throw JSONEditError(reason: "index out of range") }
        let parent = walk.chain[found]
        guard case .object(let members) = parent.kind else { throw JSONEditError(reason: "not an object") }
        let name = encoded(key)
        guard let last = members.last else {
            return try fillEmpty(parent, ancestors: walk.chain.dropLast()) { indent, inline in
                name + [UInt8(ascii: ":")] + colonGap + (try write(wrapped, indent: indent, inline: inline))
            }
        }
        let inline = isInline(parent)
        let indent = lineIndent(last.keyStart)
        let body = try write(wrapped, indent: indent, inline: inline)
        let gap = inline ? separator(after: parent) : eol + indent
        return try splice(
            last.value.end..<last.value.end, [comma] + gap + name + [UInt8(ascii: ":")] + colonGap + body)
    }

    /// Puts the first child into `{}` or `[]`, inline when the surrounding text is.
    func fillEmpty(
        _ container: JSONNode, ancestors: ArraySlice<JSONNode>, member: ([UInt8], Bool) throws -> [UInt8]
    ) throws -> Data {
        let inline = ancestors.last.map { isInline($0) } ?? false
        let range = (container.start + 1)..<(container.end - 1)
        if inline { return try splice(range, try member([], true)) }
        let base = lineIndent(container.start)
        let indent = base + unit
        return try splice(range, eol + indent + (try member(indent, false)) + eol + base)
    }

    func splice(_ range: Range<Int>, _ text: [UInt8]) throws -> Data {
        let output = Data(bytes[..<range.lowerBound] + text + bytes[range.upperBound...])
        try StrictJSON.validate(output)
        return output
    }

    func isInline(_ container: JSONNode) -> Bool {
        guard let first = container.childSpans.first else { return false }
        return !bytes[container.start..<first.lowerBound].contains(0x0A)
    }

    func lineIndent(_ position: Int) -> [UInt8] {
        var start = position
        while start > 0, bytes[start - 1] != 0x0A { start -= 1 }
        var end = start
        while end < position, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return Array(bytes[start..<end])
    }

    /// What follows a comma in this container: as written between its first two children, else the colon's gap.
    func separator(after container: JSONNode) -> [UInt8] {
        let spans = container.childSpans
        if spans.count > 1 {
            return bytes[spans[0].upperBound..<spans[1].lowerBound].filter { $0 != comma }
        }
        return colonGap
    }

    /// The whitespace after a colon, as the document writes it.
    var colonGap: [UInt8] {
        guard let member = firstMember(root) else { return [0x20] }
        let colon = bytes[member.keyEnd..<member.value.start].firstIndex(of: UInt8(ascii: ":")) ?? member.keyEnd
        return bytes[(colon + 1)..<member.value.start].filter { $0 == 0x20 || $0 == 0x09 }
    }

    private func firstMember(_ node: JSONNode) -> JSONNode.Member? {
        switch node.kind {
        case .scalar: nil
        case .object(let members): members.first
        case .array(let elements): elements.lazy.compactMap { firstMember($0) }.first
        }
    }

    func write(_ value: JSONValue, indent: [UInt8], inline: Bool) throws -> [UInt8] {
        switch value {
        case .null: return Array("null".utf8)
        case .bool(let flag): return Array((flag ? "true" : "false").utf8)
        case .number(let number): return try Self.number(number)
        case .string(let string): return encoded(string)
        case .array(let elements):
            guard !elements.isEmpty else { return Array("[]".utf8) }
            let inner = indent + unit
            let parts = try elements.map { try write($0, indent: inner, inline: inline) }
            return wrap(parts, open: "[", close: "]", indent: indent, inline: inline)
        case .object(let object):
            guard !object.isEmpty else { return Array("{}".utf8) }
            let inner = indent + unit
            let parts = try object.keys.sorted().map { key -> [UInt8] in
                let body = try write(object[key] ?? .null, indent: inner, inline: inline)
                return encoded(key) + [UInt8(ascii: ":")] + colonGap + body
            }
            return wrap(parts, open: "{", close: "}", indent: indent, inline: inline)
        }
    }

    private func wrap(_ parts: [[UInt8]], open: Character, close: Character, indent: [UInt8], inline: Bool) -> [UInt8] {
        let opening = Array(String(open).utf8)
        let closing = Array(String(close).utf8)
        if inline {
            let gap = [comma] + colonGap
            return opening + Array(parts.joined(separator: gap)) + closing
        }
        let inner = indent + unit
        let lines = parts.map { inner + $0 }
        return opening + eol + Array(lines.joined(separator: [comma] + eol)) + eol + indent + closing
    }

    private static func number(_ number: Double) throws -> [UInt8] {
        guard number.isFinite else { throw JSONEditError(reason: "a JSON number must be finite") }
        if number == number.rounded(), abs(number) < 9_007_199_254_740_992 { return Array(String(Int64(number)).utf8) }
        return Array("\(number)".utf8)
    }

    private func encoded(_ string: String) -> [UInt8] {
        var output: [UInt8] = [UInt8(ascii: "\"")]
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): output += Array("\\\"".utf8)
            case UInt8(ascii: "\\"): output += Array("\\\\".utf8)
            case 0x08: output += Array("\\b".utf8)
            case 0x09: output += Array("\\t".utf8)
            case 0x0A: output += Array("\\n".utf8)
            case 0x0C: output += Array("\\f".utf8)
            case 0x0D: output += Array("\\r".utf8)
            case 0..<0x20: output += Array(String(format: "\\u%04x", Int(byte)).utf8)
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
        return output
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func document() throws -> JSONNode {
        skipWhitespace()
        return try value()
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func value() throws -> JSONNode {
        let start = index
        switch bytes[index] {
        case UInt8(ascii: "{"):
            index += 1
            var members: [JSONNode.Member] = []
            skipWhitespace()
            while bytes[index] != UInt8(ascii: "}") {
                if bytes[index] == comma {
                    index += 1
                    skipWhitespace()
                }
                let keyStart = index
                skipString()
                let keyEnd = index
                skipWhitespace()
                index += 1
                skipWhitespace()
                let key = try decodedKey(keyStart..<keyEnd)
                members.append(.init(key: key, keyStart: keyStart, keyEnd: keyEnd, value: try value()))
                skipWhitespace()
            }
            index += 1
            return JSONNode(start: start, end: index, kind: .object(members))
        case UInt8(ascii: "["):
            index += 1
            var elements: [JSONNode] = []
            skipWhitespace()
            while bytes[index] != UInt8(ascii: "]") {
                if bytes[index] == comma {
                    index += 1
                    skipWhitespace()
                }
                elements.append(try value())
                skipWhitespace()
            }
            index += 1
            return JSONNode(start: start, end: index, kind: .array(elements))
        case UInt8(ascii: "\""):
            skipString()
        default:
            let stops: [UInt8] = [comma, UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D]
            while index < bytes.count, !stops.contains(bytes[index]) { index += 1 }
        }
        return JSONNode(start: start, end: index, kind: .scalar)
    }

    private mutating func skipString() {
        index += 1
        while bytes[index] != UInt8(ascii: "\"") {
            index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
        }
        index += 1
    }

    private func decodedKey(_ range: Range<Int>) throws -> String {
        let raw = bytes[range]
        guard raw.contains(UInt8(ascii: "\\")) else { return String(decoding: raw.dropFirst().dropLast(), as: UTF8.self) }
        guard let key = try JSONValue.parse(Data(raw)).stringValue else { throw JSONEditError(reason: "invalid key") }
        return key
    }
}
