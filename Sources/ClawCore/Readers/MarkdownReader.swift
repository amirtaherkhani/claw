import Foundation

/// One markdown definition file: a command, a subagent or a rules file.
public struct MarkdownEntry: Sendable, Equatable {
    public let name: String
    public let description: String
    public let file: String
    public let problems: [Problem]
}

/// Walks a folder of `*.md` files (bounded depth). Nested folders become `a:b` names.
public struct MarkdownReader: Sendable {
    public enum Naming: Sendable {
        /// Name from the relative path (commands: `name` frontmatter is not allowed [V `skills`]).
        case path
        /// Name from frontmatter `name`, falling back to the path (subagents [V `sub-agents`]).
        case frontmatterThenPath
    }

    private let fs: any ReadonlyFileSystem

    public init(fileSystem: any ReadonlyFileSystem) {
        self.fs = fileSystem
    }

    public func read(in directory: String, naming: Naming, maxDepth: Int = 3) -> [MarkdownEntry] {
        walk(directory, prefix: "", depth: 0, naming: naming, maxDepth: maxDepth)
    }

    private func walk(_ directory: String, prefix: String, depth: Int, naming: Naming, maxDepth: Int) -> [MarkdownEntry] {
        guard depth <= maxDepth, let entries = try? fs.contentsOfDirectory(directory) else { return [] }
        var result: [MarkdownEntry] = []
        for entry in entries where !entry.hasPrefix(".") {
            let path = joinPath(directory, entry)
            if fs.isDirectory(path) {
                result += walk(path, prefix: prefix + entry + ":", depth: depth + 1, naming: naming, maxDepth: maxDepth)
            } else if entry.hasSuffix(".md"), let data = try? fs.readFile(path) {
                result.append(
                    Self.entry(
                        text: String(decoding: data, as: UTF8.self), file: path,
                        baseName: prefix + String(entry.dropLast(3)), naming: naming))
            }
        }
        return result
    }

    static func entry(text: String, file: String, baseName: String, naming: Naming) -> MarkdownEntry {
        let frontmatter = Frontmatter.parse(text)
        var name = baseName
        if naming == .frontmatterThenPath, let declared = frontmatter?["name"], !declared.isEmpty {
            name = declared
        }
        var description = frontmatter?["description"] ?? ""
        if description.isEmpty {
            let body = frontmatter?.body ?? text
            let line =
                body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            description = String(line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(120))
        }
        var problems: [Problem] = []
        if naming == .frontmatterThenPath && frontmatter?["description"] == nil {
            problems.append(Problem(.warning, "Missing required frontmatter field `description`", file: file))
        }
        return MarkdownEntry(name: name, description: description, file: file, problems: problems)
    }
}
