import Foundation
import Testing

@testable import ClawCore

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
private func data(_ text: String) -> Data { Data(text.utf8) }

@Suite("JSON edits: examples")
struct JSONEditExampleTests {
    private func set(_ input: String, _ path: [JSONPathComponent], _ value: JSONValue) throws -> String {
        text(try JSONEdit.set(data(input), path: path, value: value))
    }

    private func remove(_ input: String, _ path: [JSONPathComponent]) throws -> String {
        text(try JSONEdit.remove(data(input), path: path))
    }

    @Test("Replacing a value keeps every other byte")
    func replace() throws {
        let input = "{\n    \"z\": 1,   \"plugins\" : {\"a@m\":  true},\n\n    \"b\": [1,2]\n}\n"
        let expected = "{\n    \"z\": 1,   \"plugins\" : {\"a@m\":  false},\n\n    \"b\": [1,2]\n}\n"
        #expect(try set(input, ["plugins", "a@m"], .bool(false)) == expected)
    }

    @Test("A new key goes last, with the indentation of its neighbours")
    func newKey() throws {
        #expect(try set("{\n    \"a\": 1\n}\n", ["b"], .bool(true)) == "{\n    \"a\": 1,\n    \"b\": true\n}\n")
        #expect(try set("{\n\t\"a\": 1\n}", ["b"], .bool(true)) == "{\n\t\"a\": 1,\n\t\"b\": true\n}")
    }

    @Test("Windows line endings stay")
    func windowsLineEndings() throws {
        let output = try set("{\r\n  \"a\": 1\r\n}\r\n", ["b"], .object(["c": .array([.number(1)])]))
        #expect(output == "{\r\n  \"a\": 1,\r\n  \"b\": {\r\n    \"c\": [\r\n      1\r\n    ]\r\n  }\r\n}\r\n")
    }

    @Test("Missing parents are created")
    func missingParents() throws {
        #expect(
            try set("{\n  \"a\": 1\n}\n", ["x", "y"], .string("v"))
                == "{\n  \"a\": 1,\n  \"x\": {\n    \"y\": \"v\"\n  }\n}\n")
    }

    @Test("An empty object opens with the file's indentation")
    func emptyObject() throws {
        #expect(try set("{}\n", ["a"], .bool(true)) == "{\n  \"a\": true\n}\n")
        #expect(
            try set("{\n    \"p\": {},\n    \"q\": 1\n}\n", ["p", "a"], .bool(true))
                == "{\n    \"p\": {\n        \"a\": true\n    },\n    \"q\": 1\n}\n")
    }

    @Test("One-line containers stay on one line")
    func inline() throws {
        #expect(try set(#"{"a":1}"#, ["b"], .bool(true)) == #"{"a":1,"b":true}"#)
        #expect(try set(#"{"a": 1, "c": 2}"#, ["b"], .array([.number(1), .number(2)])) == #"{"a": 1, "c": 2, "b": [1, 2]}"#)
        #expect(try set(#"{"a":{}}"#, ["a", "b"], .bool(true)) == #"{"a":{"b":true}}"#)
    }

    @Test("Setting the same value changes nothing, whatever its spelling")
    func sameValue() throws {
        let input = "{\"a\": [ 1,\n  2 ], \"b\": 1.0}"
        #expect(try set(input, ["a"], .array([.number(1), .number(2)])) == input)
        #expect(try set(input, ["b"], .number(1)) == input)
    }

    @Test("Keys with escapes and non-ASCII text are found and written")
    func escapes() throws {
        #expect(try set(#"{"a\"b":1}"#, [#"a"b"#], .number(2)) == #"{"a\"b":2}"#)
        #expect(try set(#"{"café":1}"#, ["café"], .number(2)) == #"{"café":2}"#)
        #expect(try set("{}", ["k"], .string("a\"\\\n\u{1}é")) == "{\n  \"k\": \"a\\\"\\\\\\n\\u0001é\"\n}")
    }

    @Test("Removing keeps the neighbours as written")
    func removal() throws {
        let input = "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3\n}\n"
        #expect(try remove(input, ["a"]) == "{\n  \"b\": 2,\n  \"c\": 3\n}\n")
        #expect(try remove(input, ["b"]) == "{\n  \"a\": 1,\n  \"c\": 3\n}\n")
        #expect(try remove(input, ["c"]) == "{\n  \"a\": 1,\n  \"b\": 2\n}\n")
        #expect(try remove("{\n  \"a\": 1\n}\n", ["a"]) == "{}\n")
    }

    @Test("Removing something absent changes nothing")
    func removeAbsent() throws {
        let input = "{\"a\": [1]}"
        #expect(try remove(input, ["b"]) == input)
        #expect(try remove(input, ["b", "c"]) == input)
        #expect(try remove(input, ["a", 3]) == input)
    }

    @Test("Array elements: remove, replace and insert (hooks)")
    func arrays() throws {
        let input = "{\n  \"h\": [\n    {\"a\": 1},\n    {\"b\": 2}\n  ]\n}\n"
        #expect(try remove(input, ["h", 0]) == "{\n  \"h\": [\n    {\"b\": 2}\n  ]\n}\n")
        #expect(try remove(input, ["h", 1]) == "{\n  \"h\": [\n    {\"a\": 1}\n  ]\n}\n")
        #expect(try set(input, ["h", 1, "b"], .number(3)) == "{\n  \"h\": [\n    {\"a\": 1},\n    {\"b\": 3}\n  ]\n}\n")
        let first = text(try JSONEdit.insert(data(input), arrayAt: ["h"], index: 0, value: .string("x")))
        #expect(first == "{\n  \"h\": [\n    \"x\",\n    {\"a\": 1},\n    {\"b\": 2}\n  ]\n}\n")
        let last = text(try JSONEdit.insert(data(input), arrayAt: ["h"], value: .string("x")))
        #expect(last == "{\n  \"h\": [\n    {\"a\": 1},\n    {\"b\": 2},\n    \"x\"\n  ]\n}\n")
    }

    @Test("Inserting into a missing or empty array")
    func emptyArrays() throws {
        #expect(text(try JSONEdit.insert(data("{}"), arrayAt: ["d"], value: .string("x"))) == "{\n  \"d\": [\n    \"x\"\n  ]\n}")
        #expect(text(try JSONEdit.insert(data(#"{"d":[]}"#), arrayAt: ["d"], value: .string("x"))) == #"{"d":["x"]}"#)
        #expect(
            text(try JSONEdit.insert(data(#"{"d":["a", "b"]}"#), arrayAt: ["d"], index: 1, value: .string("x")))
                == #"{"d":["a", "x", "b"]}"#)
    }

    @Test("Refused: broken input, wrong types, ranges, duplicate keys, an empty path")
    func refusals() {
        #expect(throws: JSONEditError.self) { try set("{\"a\":1,}", ["a"], .null) }
        #expect(throws: JSONEditError.self) { try set("{\"a\":1}", ["a", "b"], .null) }
        #expect(throws: JSONEditError.self) { try set("[1]", ["a"], .null) }
        #expect(throws: JSONEditError.self) { try set("[1]", [5], .null) }
        #expect(throws: JSONEditError.self) { try set("{}", ["a", 0], .null) }
        #expect(throws: JSONEditError.self) { try set("{\"a\":1,\"a\":2}", ["a"], .null) }
        #expect(throws: JSONEditError.self) { try set("{}", [], .null) }
        #expect(throws: JSONEditError.self) { try set("{}", ["a"], .number(.infinity)) }
        #expect(throws: JSONEditError.self) { try JSONEdit.insert(data("{\"a\":1}"), arrayAt: ["a"], value: .null) }
        #expect(throws: JSONEditError.self) { try JSONEdit.insert(data("[]"), arrayAt: [], index: 2, value: .null) }
    }
}

/// Small seeded generator, so a failure names a seed that reproduces it.
private struct Seeded {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ limit: Int) -> Int { Int(next() % UInt64(limit)) }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
}

/// A random document in one formatting style, with the raw text of each top-level member.
private struct RandomDocument {
    let keys = ["a", "b", "plugin@market", "é", "with space", "q\"uote", "x"]
    var random: Seeded
    let indent: String
    let eol: String
    let compact: Bool

    init(seed: UInt64) {
        random = Seeded(state: seed)
        indent = random.pick(["  ", "    ", "\t", " "])
        eol = random.pick(["\n", "\r\n"])
        compact = random.below(4) == 0
    }

    func quoted(_ key: String) -> String { "\"" + key.replacingOccurrences(of: "\"", with: "\\\"") + "\"" }

    mutating func value(depth: Int) -> (JSONValue, (String) -> String) {
        switch random.below(depth > 2 ? 4 : 6) {
        case 0: return (.bool(true), { _ in "true" })
        case 1: return (.null, { _ in "null" })
        case 2:
            let number = Double(random.below(1000))
            return (.number(number), { _ in String(Int(number)) })
        case 3:
            let string = random.pick(["text", "", "é", "line"])
            return (.string(string), { _ in "\"\(string)\"" })
        case 4:
            let count = random.below(4)
            var parts: [(JSONValue, (String) -> String)] = []
            for _ in 0..<count { parts.append(value(depth: depth + 1)) }
            let (compact, indent, eol) = (compact, indent, eol)
            return (
                .array(parts.map(\.0)),
                { base in
                    if parts.isEmpty { return "[]" }
                    if compact { return "[" + parts.map { $0.1("") }.joined(separator: ",") + "]" }
                    let inner = base + indent
                    return "[" + eol + parts.map { inner + $0.1(inner) }.joined(separator: "," + eol) + eol + base + "]"
                }
            )
        default:
            let (object, write) = members(depth: depth + 1)
            return (.object(object), { base in write(base).text })
        }
    }

    mutating func members(depth: Int) -> ([String: JSONValue], (String) -> (text: String, raw: [String: String])) {
        var order = keys
        var chosen: [(String, JSONValue, (String) -> String)] = []
        for _ in 0..<random.below(5) {
            let key = order.remove(at: random.below(order.count))
            let (value, write) = value(depth: depth)
            chosen.append((key, value, write))
        }
        let (compact, indent, eol) = (compact, indent, eol)
        let quote = quoted
        let object = Dictionary(uniqueKeysWithValues: chosen.map { ($0.0, $0.1) })
        return (
            object,
            { base in
                if chosen.isEmpty { return ("{}", [:]) }
                let inner = compact ? "" : base + indent
                var raw: [String: String] = [:]
                let lines = chosen.map { key, _, write -> String in
                    let line = quote(key) + (compact ? ":" : ": ") + write(inner)
                    raw[key] = line
                    return inner + line
                }
                let text =
                    compact
                    ? "{" + lines.joined(separator: ",") + "}"
                    : "{" + eol + lines.joined(separator: "," + eol) + eol + base + "}"
                return (text, raw)
            }
        )
    }

    mutating func make() -> (model: [String: JSONValue], text: String, raw: [String: String]) {
        let (object, write) = members(depth: 0)
        let (text, raw) = write("")
        return (object, text + (compact ? "" : eol), raw)
    }
}

@Suite("JSON edits: properties")
struct JSONEditPropertyTests {
    private let seeds: [UInt64] = Array(1...600)

    private func newValue(_ random: inout Seeded) -> JSONValue {
        random.pick([
            .bool(false), .string("new"), .number(42), .array([.number(1), .string("two")]),
            .object(["k": .bool(true), "l": .array([])]), .object([:]),
        ])
    }

    /// A compact document has no line ending to keep; `{}` in one gets the default.
    private func checkStyle(_ output: Data, _ document: RandomDocument, seed: UInt64) {
        guard !document.compact else { return }
        let string = text(output)
        if document.eol == "\r\n" {
            #expect(!string.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "bare LF, seed \(seed)")
        } else {
            #expect(!string.contains("\r"), "CR added, seed \(seed)")
        }
    }

    @Test("set: right value, other members untouched, idempotent, style kept")
    func setProperties() throws {
        for seed in seeds {
            var document = RandomDocument(seed: seed)
            let (model, input, raw) = document.make()
            var random = Seeded(state: seed ^ 0xABCD)
            let key = random.pick(document.keys)
            let value = newValue(&random)
            let once = try JSONEdit.set(data(input), path: [.key(key)], value: value)

            var expected = model
            expected[key] = value
            #expect(try JSONValue.parse(once) == .object(expected), "value, seed \(seed)")
            #expect(try JSONEdit.set(once, path: [.key(key)], value: value) == once, "idempotent, seed \(seed)")
            for (other, line) in raw where other != key {
                #expect(text(once).contains(line), "member \(other) changed, seed \(seed)")
            }
            checkStyle(once, document, seed: seed)
        }
    }

    @Test("remove: gone, other members untouched, idempotent, style kept")
    func removeProperties() throws {
        for seed in seeds {
            var document = RandomDocument(seed: seed)
            let (model, input, raw) = document.make()
            var random = Seeded(state: seed ^ 0x1234)
            let key = random.pick(document.keys)
            let once = try JSONEdit.remove(data(input), path: [.key(key)])

            var expected = model
            expected[key] = nil
            #expect(try JSONValue.parse(once) == .object(expected), "value, seed \(seed)")
            #expect(try JSONEdit.remove(once, path: [.key(key)]) == once, "idempotent, seed \(seed)")
            for (other, line) in raw where other != key {
                #expect(text(once).contains(line), "member \(other) changed, seed \(seed)")
            }
            checkStyle(once, document, seed: seed)
        }
    }

    @Test("Adding a key and removing it returns the same bytes")
    func addThenRemove() throws {
        for seed in seeds {
            var document = RandomDocument(seed: seed)
            let (model, input, _) = document.make()
            guard !model.isEmpty else { continue }
            var random = Seeded(state: seed ^ 0x77)
            let added = try JSONEdit.set(data(input), path: ["fresh-key"], value: newValue(&random))
            #expect(try JSONEdit.remove(added, path: ["fresh-key"]) == data(input), "seed \(seed)")
        }
    }

    @Test("Inserting into an array and removing the element returns the same bytes")
    func insertThenRemove() throws {
        for seed in seeds {
            var random = Seeded(state: seed)
            let count = 1 + random.below(4)
            let items = (0..<count).map { "{\"n\": \($0)}" }
            let multiline = random.below(2) == 0
            let input =
                multiline
                ? "{\n  \"list\": [\n    " + items.joined(separator: ",\n    ") + "\n  ]\n}\n"
                : "{\"list\": [" + items.joined(separator: ", ") + "]}"
            let index = random.below(count + 1)
            let inserted = try JSONEdit.insert(data(input), arrayAt: ["list"], index: index, value: .string("new"))
            let list = try #require(try JSONValue.parse(inserted)["list"]?.arrayValue)
            #expect(list[index] == .string("new"), "seed \(seed)")
            #expect(list.count == count + 1, "seed \(seed)")
            #expect(try JSONEdit.remove(inserted, path: ["list", .index(index)]) == data(input), "seed \(seed)")
        }
    }
}
