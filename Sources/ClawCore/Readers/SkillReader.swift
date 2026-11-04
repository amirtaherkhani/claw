import Foundation

public struct SkillRecord: Sendable, Equatable {
    public let name: String
    public let description: String
    public let directory: String
    public let file: String
    public let disableModelInvocation: Bool
    public let userInvocable: Bool
    public let problems: [Problem]
}

/// Reads `<dir>/<skill>/SKILL.md` files [V `skills`].
public struct SkillReader: Sendable {
    private let fs: any ReadonlyFileSystem

    public init(fileSystem: any ReadonlyFileSystem) {
        self.fs = fileSystem
    }

    public func readSkills(in directory: String, skipping skip: Set<String> = []) -> [SkillRecord] {
        guard let entries = try? fs.contentsOfDirectory(directory) else { return [] }
        return entries.compactMap { entry -> SkillRecord? in
            guard !entry.hasPrefix("."), !skip.contains(entry) else { return nil }
            let folder = joinPath(directory, entry)
            let file = joinPath(folder, "SKILL.md")
            guard fs.isDirectory(folder), let data = try? fs.readFile(file) else { return nil }
            return record(folderName: entry, folder: folder, file: file, text: String(decoding: data, as: UTF8.self))
        }
    }

    func record(folderName: String, folder: String, file: String, text: String) -> SkillRecord {
        var problems: [Problem] = []
        let frontmatter = Frontmatter.parse(text)
        if frontmatter == nil {
            problems.append(Problem(.warning, "SKILL.md has no frontmatter; the folder name is used", file: file))
        }
        let name = frontmatter?["name"].flatMap { $0.isEmpty ? nil : $0 } ?? folderName
        let description = frontmatter?["description"] ?? ""
        if frontmatter != nil && description.isEmpty {
            problems.append(Problem(.note, "Skill has no description", file: file))
        }
        return SkillRecord(
            name: name,
            description: description,
            directory: folder,
            file: file,
            disableModelInvocation: frontmatter?["disable-model-invocation"] == "true",
            userInvocable: frontmatter?["user-invocable"] != "false",
            problems: problems
        )
    }
}
