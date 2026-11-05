import Foundation
import Testing

@testable import ClawCore

private let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])

private func item(
    _ concept: Concept, _ name: String, scope: ItemScope = .project, ownership: Ownership = .personal,
    location: String = "/p/x", description: String = "", key: String? = nil, enabledByFile: String? = nil,
    projectPath: String? = "/p", mechanism: ControlMechanism = .none
) -> Item {
    Item(
        concept: concept, key: name, name: name, description: description, scope: scope, projectPath: projectPath,
        classification: Classification(ownership: ownership, rule: "T", evidence: []), location: location, enabled: true,
        enabledByFile: enabledByFile, control: ControlRef(mechanism: mechanism, key: key ?? name, status: .verified),
        capabilities: .forOwnership(ownership, isPlugin: concept == .plugins))
}

private func plugin(_ id: String, scope: ItemScope = .user, ownership: Ownership = .market) -> Item {
    item(
        .plugins, id, scope: scope, ownership: ownership, key: "enabledPlugins[\"\(id)\"]",
        enabledByFile: "/h/.claude/settings.json", projectPath: scope == .user ? nil : "/p", mechanism: .enabledPlugins)
}

private func hook(_ event: String, _ group: Int, _ handler: Int, summary: String, matcher: String? = nil) -> Item {
    let label = matcher.map { " [\($0)]" } ?? ""
    return Item(
        concept: .hooks, key: "\(event)/\(group)/\(handler)", name: "\(event)\(label) · \(summary)",
        description: "command hook", scope: .user,
        classification: Classification(ownership: .personal, rule: "T", evidence: []),
        location: "/h/.claude/settings.json › hooks.\(event)[\(group)].hooks[\(handler)]", enabled: true,
        control: ControlRef(mechanism: .hookStash, key: "stash", status: .verified),
        capabilities: Capabilities(edit: true, toggle: true, remove: true, removeLabel: "Remove entry", reason: nil))
}

private func text(_ edit: FileEdit?) -> String { String(decoding: edit?.after ?? Data(), as: UTF8.self) }

@Suite("Planner: remove")
struct RemovePlannerTests {
    private let empty = Planner(environment: env, fileSystem: MemoryFileSystem([:]))

    @Test("Uninstalling a plugin is a CLI step that keeps data by default")
    func pluginKeepsData() throws {
        let change = try empty.remove(plugin("kit@market"))
        #expect(
            change.cli == [
                CliStep(argv: ["plugin", "uninstall", "kit@market", "--scope", "user", "--keep-data"], workingDirectory: nil)
            ])
        #expect(change.edits.isEmpty)
        #expect(change.moves.isEmpty)
        #expect(change.effect == .reloadPlugins)
        #expect(change.cliTouches.contains("/h/.claude/settings.json"))
        #expect(change.cliTouches.contains("/h/.claude/plugins/installed_plugins.json"))
    }

    @Test("Without Keep data the warning says the data goes")
    func pluginDataWarning() throws {
        let change = try empty.remove(plugin("kit@market"), keepData: false)
        #expect(!(change.cli.first?.argv.contains("--keep-data") ?? true))
        #expect(change.warnings.contains { $0.contains("data") })
    }

    @Test("A project plugin runs in its project, at its scope")
    func projectPlugin() throws {
        let change = try empty.remove(plugin("kit@market", scope: .project))
        #expect(change.cli.first?.argv.contains("project") == true)
        #expect(change.cli.first?.workingDirectory == "/p")
        #expect(change.cliTouches.contains("/p/.claude/settings.json"))
    }

    @Test("An orphaned plugin loses its settings entry, with no CLI step")
    func orphan() throws {
        let file = "/h/.claude/settings.json"
        let planner = Planner(
            environment: env,
            fileSystem: MemoryFileSystem([file: "{\n  \"enabledPlugins\": {\n    \"gone@m\": true\n  }\n}\n"]))
        let change = try planner.remove(plugin("gone@m", ownership: .orphan))
        #expect(change.cli.isEmpty)
        #expect(text(change.edits.first) == "{}\n")
    }

    @Test("Hostile names never reach the CLI", arguments: ["kit; rm -rf /", "--help", "a b", "$(x)@m", "kit@m@n"])
    func hostilePlugin(id: String) {
        #expect(throws: PlanError.self) { try empty.remove(plugin(id)) }
    }

    @Test("Files move to the backup, whatever the concept", arguments: [Concept.skills, .commands, .agents, .rules])
    func movesFiles(concept: Concept) throws {
        let change = try empty.remove(item(concept, "thing", location: "/p/.claude/thing"))
        #expect(change.moves == ["/p/.claude/thing"])
        #expect(change.edits.isEmpty)
        #expect(change.cli.isEmpty)
    }

    @Test("A .mcp.json server is cut from the file; others stay")
    func mcpJson() throws {
        let file = "/p/.mcp.json"
        let before =
            "{\n  \"mcpServers\": {\n    \"db\": {\n      \"command\": \"x\"\n    },\n    \"keep\": {\n      \"command\": \"y\"\n    }\n  }\n}\n"
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([file: before]))
        let change = try planner.remove(item(.mcp, "db", location: file, description: "stdio · x"))
        #expect(change.edits.first?.file == file)
        #expect(text(change.edits.first) == "{\n  \"mcpServers\": {\n    \"keep\": {\n      \"command\": \"y\"\n    }\n  }\n}\n")
        #expect(change.cli.isEmpty)
        #expect(change.warnings.isEmpty)
    }

    @Test("The last .mcp.json server leaves an empty list, not an empty file")
    func mcpJsonLast() throws {
        let file = "/p/.mcp.json"
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([file: "{\"mcpServers\":{\"db\":{}}}"]))
        let change = try planner.remove(item(.mcp, "db", location: file))
        #expect(text(change.edits.first) == "{\"mcpServers\":{}}")
    }

    @Test("User and local servers go through the CLI, and .claude.json is backed up")
    func mcpCli() throws {
        let user = try empty.remove(item(.mcp, "github", scope: .user, location: "/h/.claude.json", projectPath: nil))
        #expect(user.cli == [CliStep(argv: ["mcp", "remove", "github", "--scope", "user"], workingDirectory: nil)])
        #expect(user.cliTouches == ["/h/.claude.json"])
        let local = try empty.remove(item(.mcp, "tool", scope: .local, location: "/h/.claude.json"))
        #expect(local.cli == [CliStep(argv: ["mcp", "remove", "tool", "--scope", "local"], workingDirectory: "/p")])
    }

    @Test("Removing a remote server warns about its sign-in", arguments: ["http · api.example.com", "sse · api.example.com"])
    func remoteWarning(description: String) throws {
        let server = item(.mcp, "github", scope: .user, location: "/h/.claude.json", description: description, projectPath: nil)
        #expect(try empty.remove(server).warnings.contains { $0.contains("sign-in") })
    }

    @Test("An MCP name the CLI would not accept is refused", arguments: ["bad name", "-x", "a;b"])
    func hostileMcp(name: String) {
        #expect(throws: PlanError.self) {
            try empty.remove(item(.mcp, name, scope: .user, location: "/h/.claude.json", projectPath: nil))
        }
    }

    private static let hooks = """
        {
          "hooks": {
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {"type": "command", "command": "/usr/local/bin/guard.sh --token secret"},
                  {"type": "command", "command": "/bin/second.sh"}
                ]
              }
            ],
            "Stop": [
              {
                "hooks": [
                  {"type": "command", "command": "/bin/stop.sh"}
                ]
              }
            ]
          }
        }

        """

    private var hookPlanner: Planner {
        Planner(environment: env, fileSystem: MemoryFileSystem(["/h/.claude/settings.json": Self.hooks]))
    }

    @Test("A hook leaves its group, and an empty group or event goes too")
    func hookRemoval() throws {
        let one = try hookPlanner.remove(hook("PreToolUse", 0, 1, summary: "second.sh", matcher: "Bash"))
        let first = try JSONValue.parse(try #require(one.edits.first).after)
        #expect(first["hooks"]?["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.count == 1)

        let last = try hookPlanner.remove(hook("Stop", 0, 0, summary: "stop.sh"))
        let second = try JSONValue.parse(try #require(last.edits.first).after)
        #expect(second["hooks"]?["Stop"] == nil)
        #expect(second["hooks"]?["PreToolUse"] != nil)
    }

    @Test("A guard hook gets a warning, and the warning holds no command")
    func guardWarning() throws {
        let change = try hookPlanner.remove(hook("PreToolUse", 0, 0, summary: "guard.sh", matcher: "Bash"))
        #expect(change.warnings.contains { $0.contains("Guard") })
        #expect(!change.warnings.joined().contains("secret"))
        let quiet = try hookPlanner.remove(hook("Stop", 0, 0, summary: "stop.sh"))
        #expect(quiet.warnings.isEmpty)
    }

    @Test("A hook that moved since the scan is refused")
    func hookMoved() {
        #expect(throws: PlanError.self) {
            try hookPlanner.remove(hook("PreToolUse", 0, 1, summary: "guard.sh", matcher: "Bash"))
        }
        #expect(throws: PlanError.self) { try hookPlanner.remove(hook("Stop", 3, 0, summary: "stop.sh")) }
    }

    @Test("Removing several hooks of one file keeps each index right")
    func hookBatch() throws {
        let changes = try hookPlanner.remove(
            [
                hook("PreToolUse", 0, 0, summary: "guard.sh", matcher: "Bash"),
                hook("PreToolUse", 0, 1, summary: "second.sh", matcher: "Bash"),
            ])
        let json = try JSONValue.parse(try #require(changes.last?.edits.first).after)
        #expect(json["hooks"]?["PreToolUse"] == nil)
        #expect(json["hooks"]?["Stop"] != nil)
    }

    @Test("Refused: synced, managed and plugin-provided items", arguments: [Ownership.synced, .managed, .plugin])
    func refused(ownership: Ownership) {
        #expect(throws: PlanError.self) { try empty.remove(item(.skills, "s", ownership: ownership)) }
    }
}
