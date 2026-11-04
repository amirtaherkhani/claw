import Foundation

public struct RuleFile: Sendable, Equatable {
    public let path: String
    public let scope: ItemScope
    public let projectPath: String?
}

/// Finds memory and rules files [V `memory`].
public struct RuleReader: Sendable {
    private let fs: any ReadonlyFileSystem

    public init(fileSystem: any ReadonlyFileSystem) {
        self.fs = fileSystem
    }

    public func ruleFiles(environment env: ClaudeEnvironment, includeUser: Bool) -> [RuleFile] {
        var files: [RuleFile] = []
        func add(_ path: String, _ scope: ItemScope, _ project: String?) {
            if fs.fileExists(path) && !fs.isDirectory(path) {
                files.append(RuleFile(path: path, scope: scope, projectPath: project))
            }
        }
        func addTree(_ dir: String, _ scope: ItemScope, _ project: String?) {
            for entry in MarkdownReader(fileSystem: fs).read(in: dir, naming: .path) {
                files.append(RuleFile(path: entry.file, scope: scope, projectPath: project))
            }
        }

        add(joinPath(env.managedDir, "CLAUDE.md"), .managed, nil)
        if includeUser {
            add(joinPath(env.configDir, "CLAUDE.md"), .user, nil)
            addTree(joinPath(env.configDir, "rules"), .user, nil)
        }
        for project in env.projects {
            add(joinPath(project, "CLAUDE.md"), .project, project)
            add(joinPath(project, ".claude", "CLAUDE.md"), .project, project)
            add(joinPath(project, "CLAUDE.local.md"), .local, project)
            addTree(joinPath(project, ".claude", "rules"), .project, project)
        }
        return files
    }
}

/// Glob matching for `claudeMdExcludes` against absolute paths: `**` crosses folders, `*` and `?` do not.
/// The exact glob dialect Claude Code uses is not documented; this is the common one [A].
public enum Glob {
    public static func matches(_ pattern: String, _ path: String) -> Bool {
        var regex = "^"
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let char = pattern[index]
            let next = pattern.index(after: index)
            if char == "*" {
                if next < pattern.endIndex, pattern[next] == "*" {
                    let afterStars = pattern.index(after: next)
                    if afterStars < pattern.endIndex, pattern[afterStars] == "/" {
                        regex += "(?:.*/)?"
                        index = pattern.index(after: afterStars)
                    } else {
                        regex += ".*"
                        index = afterStars
                    }
                    continue
                }
                regex += "[^/]*"
            } else if char == "?" {
                regex += "[^/]"
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
            }
            index = next
        }
        regex += "$"
        guard let expression = try? NSRegularExpression(pattern: regex) else { return false }
        return expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }
}
