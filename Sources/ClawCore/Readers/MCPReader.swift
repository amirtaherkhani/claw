import Foundation

/// An MCP server definition reduced to what the UI may show. `args`, `env`, `headers` and full URLs
/// are never kept, so no secret can leak through a scan result.
public struct MCPServerRecord: Sendable, Equatable {
    public let name: String
    /// `stdio`, `http`, `streamable-http`, `sse`, `ws` …
    public let transport: String
    /// Executable basename for stdio, host for remote servers.
    public let summary: String
    public let file: String
    public let scope: ItemScope
    public let projectPath: String?
}

public struct ClaudeJSONServers: Sendable {
    public var user: [MCPServerRecord] = []
    public var local: [MCPServerRecord] = []
    /// `projects[<path>].disabledMcpServers`, by project path.
    public var disabledByProject: [String: Set<String>] = [:]
    public var problems: [Problem] = []
}

public struct MCPReader: Sendable {
    private let fs: any ReadonlyFileSystem

    public init(fileSystem: any ReadonlyFileSystem) {
        self.fs = fileSystem
    }

    /// `.mcp.json` (project scope) or a plugin's `.mcp.json`: top key `mcpServers` [V `mcp`]. A plugin's file may
    /// also list the servers at the top level [V `docs/compare-m1.md`].
    public func readMcpJson(file: String, scope: ItemScope, projectPath: String?) -> ([MCPServerRecord], [Problem]) {
        guard let data = try? fs.readFile(file) else { return ([], []) }
        guard let value = try? JSONValue.parse(data), value.objectValue != nil else {
            return ([], [Problem(.error, "MCP file is not a valid JSON object; it was skipped", file: file)])
        }
        guard let servers = value["mcpServers"] else {
            guard scope == .plugin, let flat = value.objectValue, flat.values.allSatisfy({ $0.objectValue != nil }) else {
                return ([], [])
            }
            return (Self.records(flat, file: file, scope: scope, projectPath: projectPath), [])
        }
        guard let object = servers.objectValue else {
            return ([], [Problem(.warning, "`mcpServers` is not an object; it was ignored", file: file)])
        }
        return (Self.records(object, file: file, scope: scope, projectPath: projectPath), [])
    }

    /// Servers declared inline in a plugin's `plugin.json` [V `docs/compare-m1.md`]. A path there is not read yet.
    public func readPluginManifest(file: String, projectPath: String?) -> [MCPServerRecord] {
        guard let data = try? fs.readFile(file), let value = try? JSONValue.parse(data),
            let object = value["mcpServers"]?.objectValue
        else { return [] }
        return Self.records(object, file: file, scope: .plugin, projectPath: projectPath)
    }

    /// `~/.claude.json`: user servers at the top level, local servers and `disabledMcpServers` under
    /// `projects[<path>]` [V purpose `mcp`; exact JSON paths are assumptions until spike S1].
    public func readClaudeJson(file: String, projects: [String]) -> ClaudeJSONServers {
        var result = ClaudeJSONServers()
        guard let data = try? fs.readFile(file) else { return result }
        guard let value = try? JSONValue.parse(data), value.objectValue != nil else {
            result.problems.append(
                Problem(.error, "~/.claude.json is not a valid JSON object; its MCP servers were skipped", file: file))
            return result
        }
        if let user = value["mcpServers"]?.objectValue {
            result.user = Self.records(user, file: file, scope: .user, projectPath: nil)
        }
        let projectStates = value["projects"]?.objectValue ?? [:]
        for project in projects {
            guard let state = projectStates[project] else { continue }
            if let local = state["mcpServers"]?.objectValue {
                result.local += Self.records(local, file: file, scope: .local, projectPath: project)
            }
            let disabled = state["disabledMcpServers"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !disabled.isEmpty { result.disabledByProject[project] = Set(disabled) }
        }
        return result
    }

    static func records(_ servers: [String: JSONValue], file: String, scope: ItemScope, projectPath: String?) -> [MCPServerRecord]
    {
        servers.keys.sorted().map { name in
            let entry = servers[name] ?? .null
            let url = entry["url"]?.stringValue
            let transport = entry["type"]?.stringValue ?? (url != nil ? "http" : "stdio")
            let summary: String
            if let url, let host = URLComponents(string: url)?.host {
                summary = host
            } else if let command = entry["command"]?.stringValue {
                summary = CommandSummary.executable(command)
            } else {
                summary = transport
            }
            return MCPServerRecord(
                name: name, transport: transport, summary: summary, file: file, scope: scope,
                projectPath: projectPath)
        }
    }
}

/// Reduces a command line to its executable's basename: never arguments, never `VAR=value` prefixes.
public enum CommandSummary {
    public static func executable(_ command: String) -> String {
        let tokens = command.split(whereSeparator: \.isWhitespace).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        guard let first = tokens.first(where: { !$0.isEmpty && !$0.contains("=") && $0 != "env" && $0 != "exec" }) else {
            return "command"
        }
        return URL(fileURLWithPath: first).lastPathComponent
    }
}
