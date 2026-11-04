import Foundation

/// Projects Claude Code already knows: the keys of `projects` in `~/.claude.json` [V key exists `mcp`;
/// keys being absolute paths is an assumption until spike S1]. Only folders that still exist are returned.
public struct ProjectDiscovery: Sendable {
    private let fs: any ReadonlyFileSystem

    public init(fileSystem: any ReadonlyFileSystem) {
        self.fs = fileSystem
    }

    public func knownProjects(environment env: ClaudeEnvironment) -> [String] {
        guard let data = try? fs.readFile(env.claudeJsonFile), let value = try? JSONValue.parse(data),
            let projects = value["projects"]?.objectValue
        else { return [] }
        return ProjectRegistry.deduplicated(
            projects.keys.filter { $0.hasPrefix("/") && fs.isDirectory($0) }, fileSystem: fs)
    }
}

public struct RegisteredProject: Codable, Sendable, Equatable {
    public let path: String
    public let addedAt: Date

    public init(path: String, addedAt: Date) {
        self.path = path
        self.addedAt = addedAt
    }
}

/// Clef's own list of project folders (PRD F03). Stored in Clef's application-support folder, never
/// in Claude Code's configuration. Pure list operations are separate from loading and saving.
public struct ProjectRegistry: Sendable {
    public let file: String

    public init(file: String) {
        self.file = file
    }

    /// `~/Library/Application Support/Clef/projects.json` on macOS; `$XDG_CONFIG_HOME/clef/projects.json`
    /// (default `~/.config/clef`) elsewhere.
    public static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment, home: String)
        -> String
    {
        #if os(macOS)
            joinPath(home, "Library", "Application Support", "Clef", "projects.json")
        #else
            joinPath(
                environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? joinPath(home, ".config"),
                "clef", "projects.json")
        #endif
    }

    public func load(fileSystem fs: any ReadonlyFileSystem) -> ([RegisteredProject], [Problem]) {
        guard let data = try? fs.readFile(file) else { return ([], []) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let projects = try? decoder.decode([RegisteredProject].self, from: data) else {
            return ([], [Problem(.error, "Project list is unreadable; it was ignored (the file is kept)", file: file)])
        }
        return (projects, [])
    }

    /// Writes atomically (temporary file, then rename) with owner-only permissions.
    public func save(_ projects: [RegisteredProject]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let url = URL(fileURLWithPath: file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try encoder.encode(projects).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }

    /// Adds a folder unless it (or another path to the same folder) is already registered.
    public static func adding(
        _ path: String, to projects: [RegisteredProject], now: Date = Date(), fileSystem fs: any ReadonlyFileSystem
    ) -> [RegisteredProject] {
        let real = fs.resolvingSymlinks(path)
        guard !projects.contains(where: { fs.resolvingSymlinks($0.path) == real }) else { return projects }
        return projects + [RegisteredProject(path: path, addedAt: now)]
    }

    public static func removing(
        _ path: String, from projects: [RegisteredProject], fileSystem fs: any ReadonlyFileSystem
    ) -> [RegisteredProject] {
        let real = fs.resolvingSymlinks(path)
        return projects.filter { fs.resolvingSymlinks($0.path) != real }
    }

    /// Removes paths that resolve to the same folder; keeps the first spelling, sorted.
    public static func deduplicated(_ paths: [String], fileSystem fs: any ReadonlyFileSystem) -> [String] {
        var seen = Set<String>()
        return paths.sorted().filter { seen.insert(fs.resolvingSymlinks($0)).inserted }
    }
}
