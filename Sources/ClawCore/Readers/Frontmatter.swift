import Foundation

/// Minimal YAML frontmatter reader for `SKILL.md`, commands and subagents.
/// Supports `key: value`, quoted values and `>` / `|` block scalars. Lists and nested maps are skipped.
public struct Frontmatter: Sendable, Equatable {
    public let fields: [String: String]
    public let body: String

    public subscript(key: String) -> String? { fields[key] }

    /// `nil` when the text does not start with a `---` fence or the fence is not closed.
    public static func parse(_ text: String) -> Frontmatter? {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }

        var fields: [String: String] = [:]
        var index = 1
        while index < end {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                let colon = line.firstIndex(of: ":")
            else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let rawValue = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            if ["|", "|-", ">", ">-"].contains(rawValue) {
                var block: [String] = []
                while index < end, lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") || lines[index].isEmpty {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let separator = rawValue.hasPrefix("|") ? "\n" : " "
                fields[key] = block.joined(separator: separator).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                fields[key] = unquote(rawValue)
            }
        }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return Frontmatter(fields: fields, body: body)
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        else { return value }
        return String(value.dropFirst().dropLast())
    }
}
