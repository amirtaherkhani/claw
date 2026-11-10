import Foundation

/// A small line diff for showing a plan to a person. Files here are settings files, so a quadratic table is fine.
public enum LineDiff {
    /// `  ` unchanged, `- ` removed, `+ ` added; `  ⋯` marks lines left out between two changes.
    public static func unified(old: String, new: String, context: Int = 3) -> [String] {
        let a = lines(old)
        let b = lines(new)
        // Longest common subsequence table, filled from the end.
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var ops: [(mark: Character, text: String)] = []
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                ops.append((" ", a[i]))
                i += 1
                j += 1
            } else if i < a.count, j == b.count || table[i + 1][j] >= table[i][j + 1] {
                ops.append(("-", a[i]))
                i += 1
            } else {
                ops.append(("+", b[j]))
                j += 1
            }
        }
        guard ops.contains(where: { $0.mark != " " }) else { return [] }

        var keep = [Bool](repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() where op.mark != " " {
            for near in max(0, index - context)...min(ops.count - 1, index + context) { keep[near] = true }
        }
        var result: [String] = []
        var skipped = false
        for (index, op) in ops.enumerated() {
            if keep[index] {
                if skipped, !result.isEmpty { result.append("  ⋯") }
                skipped = false
                result.append("\(op.mark) \(op.text)")
            } else {
                skipped = true
            }
        }
        return result
    }

    private static func lines(_ text: String) -> [String] {
        var parts = text.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }
}

/// How a file change is shown. JSON is normalised (sorted keys, two spaces) with secret values masked by `Redactor`,
/// on both sides. Anything else shows sizes only, so no file body can reach a terminal or a log.
public enum ChangeView {
    public static func lines(file: String, before: Data?, after: Data) -> [String] {
        let oldText: String
        if let before {
            guard let value = try? JSONValue.parse(before) else { return sizes(before, after) }
            oldText = render(value)
        } else {
            oldText = ""
        }
        guard let newValue = try? JSONValue.parse(after) else { return sizes(before, after) }
        return LineDiff.unified(old: oldText, new: render(newValue))
    }

    private static func sizes(_ before: Data?, _ after: Data) -> [String] {
        ["  (not JSON: \(before?.count ?? 0) bytes → \(after.count) bytes, content not shown)"]
    }

    private static func render(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Redactor.redact(value))) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
