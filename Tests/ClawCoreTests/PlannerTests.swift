import Foundation
import Testing

@testable import ClawCore

private let goldens = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Goldens/plan")

private func golden(_ name: String) throws -> String {
    try String(contentsOf: goldens.appendingPathComponent(name), encoding: .utf8)
}

private let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
private let local = WriteScope(scope: .local, file: "/p/.claude/settings.local.json")
private let user = WriteScope(scope: .user, file: "/h/.claude/settings.json")

private func item(
    _ concept: Concept, _ name: String, _ mechanism: ControlMechanism, key: String, enabled: Bool = true,
    status: VerificationStatus = .verified, location: String = "/p/x", enabledBy: String? = nil,
    ownership: Ownership = .personal, projectPath: String? = "/p"
) -> Item {
    Item(
        concept: concept, key: name, name: name, description: "", scope: .project, projectPath: projectPath,
        classification: Classification(ownership: ownership, rule: "T", evidence: []), location: location, enabled: enabled,
        enabledBy: enabledBy, control: ControlRef(mechanism: mechanism, key: key, status: status),
        capabilities: .forOwnership(ownership, isPlugin: concept == .plugins))
}

private let plugin = item(.plugins, "kit@market", .enabledPlugins, key: "enabledPlugins[\"kit@market\"]")
private let skill = item(.skills, "plan-review", .skillOverrides, key: "skillOverrides[\"plan-review\"]")
private let command = item(.commands, "/deploy", .skillOverrides, key: "skillOverrides[\"deploy\"]")
private let rule = item(
    .rules, "security.md", .claudeMdExcludes, key: "claudeMdExcludes: /p/.claude/rules/security.md",
    location: "/p/.claude/rules/security.md")
private let agent = item(.agents, "nest-reviewer", .permissionsDeny, key: "permissions.deny: Agent(nest-reviewer)")
private let mcpJson = item(.mcp, "db", .disabledMcpjsonServers, key: "disabledMcpjsonServers: db")
private let mcp = item(.mcp, "github", .disabledMcpServers, key: "projects[<path>].disabledMcpServers")

private func disabled(_ source: Item) -> Item {
    item(
        source.concept, source.name, source.control.mechanism, key: source.control.key, enabled: false,
        location: source.location)
}

@Suite("Planner: setEnabled")
struct PlannerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let golden: String
        let item: Item
        let enabled: Bool
        let scope: WriteScope
        let file: String
        let effect: PlanEffect
        var testDescription: String { golden }

        init(
            _ golden: String, _ item: Item, enabled: Bool, scope: WriteScope = local, file: String? = nil, effect: PlanEffect
        ) {
            self.golden = golden
            self.item = item
            self.enabled = enabled
            self.scope = scope
            self.file = file ?? scope.file
            self.effect = effect
        }
    }

    static let cases: [Case] = [
        Case("plugin-disable", plugin, enabled: false, scope: user, effect: .reloadPlugins),
        Case("plugin-enable-new-key", disabled(plugin), enabled: true, scope: user, effect: .reloadPlugins),
        Case("skill-disable", skill, enabled: false, effect: .live),
        Case("skill-enable-removes", disabled(skill), enabled: true, effect: .live),
        Case("skill-enable-keeps-others", disabled(skill), enabled: true, effect: .live),
        Case("skill-enable-over-lower-scope", disabled(skill), enabled: true, effect: .live),
        Case("command-disable", command, enabled: false, effect: .live),
        Case("rule-exclude", rule, enabled: false, effect: .afterClear),
        Case("rule-include", disabled(rule), enabled: true, effect: .afterClear),
        Case("agent-deny", agent, enabled: false, effect: .live),
        Case("agent-allow", disabled(agent), enabled: true, effect: .live),
        Case("mcpjson-disable", mcpJson, enabled: false, effect: .newSession),
        Case("mcpjson-enable", disabled(mcpJson), enabled: true, effect: .newSession),
        Case("mcp-disable", mcp, enabled: false, file: "/h/.claude.json", effect: .newSession),
        Case("mcp-enable", disabled(mcp), enabled: true, file: "/h/.claude.json", effect: .newSession),
    ]

    @Test("Before and after per concept", arguments: cases)
    func goldenCase(_ test: Case) throws {
        let before = try golden("\(test.golden).before.json")
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([test.file: before]))
        let change = try planner.setEnabled(test.item, enabled: test.enabled, writeScope: test.scope, activeProject: "/p")
        let edit = try #require(change.edits.first)
        #expect(change.edits.count == 1)
        #expect(edit.file == test.file)
        #expect(edit.before == Data(before.utf8))
        #expect(String(decoding: edit.after, as: UTF8.self) == (try golden("\(test.golden).after.json")))
        #expect(change.effect == test.effect)
        #expect(change.itemId == test.item.id)
    }

    @Test("Disable then enable returns the same bytes", arguments: [plugin, skill, command, rule, agent, mcpJson, mcp])
    func roundTrip(_ source: Item) throws {
        let file = source.control.mechanism == .disabledMcpServers ? "/h/.claude.json" : local.file
        let start =
            "{\n    \"theme\": \"dark\",\n    \"projects\": {\n        \"/p\": {\n            \"a\": 1\n        }\n    }\n}\n"
        let off = try Planner(environment: env, fileSystem: MemoryFileSystem([file: start]))
            .setEnabled(source, enabled: false, writeScope: local, activeProject: "/p")
        let middle = String(decoding: try #require(off.edits.first).after, as: UTF8.self)
        let on = try Planner(environment: env, fileSystem: MemoryFileSystem([file: middle]))
            .setEnabled(disabled(source), enabled: true, writeScope: local, activeProject: "/p")
        guard source.control.mechanism != .enabledPlugins else { return }
        #expect(String(decoding: try #require(on.edits.first).after, as: UTF8.self) == start)
    }

    @Test("A file that does not exist yet starts empty")
    func newFile() throws {
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([:]))
        let change = try planner.setEnabled(skill, enabled: false, writeScope: local, activeProject: "/p")
        let edit = try #require(change.edits.first)
        #expect(edit.before == nil)
        #expect(
            String(decoding: edit.after, as: UTF8.self) == "{\n  \"skillOverrides\": {\n    \"plan-review\": \"off\"\n  }\n}\n")
    }

    @Test("Already in the wanted state: no edit")
    func noChange() throws {
        let text = "{\n  \"skillOverrides\": {\n    \"plan-review\": \"off\"\n  }\n}\n"
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([local.file: text]))
        let change = try planner.setEnabled(skill, enabled: false, writeScope: local, activeProject: "/p")
        #expect(change.edits.isEmpty)
    }

    @Test("A deny rule goes in once")
    func denyOnce() throws {
        let text = "{\"permissions\":{\"deny\":[\"Agent(nest-reviewer)\"]}}"
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([local.file: text]))
        #expect(try planner.setEnabled(agent, enabled: false, writeScope: local, activeProject: "/p").edits.isEmpty)
    }

    @Test("A .mcp.json server off through /mcp disable is enabled in .claude.json")
    func mcpJsonOffByCommand() throws {
        let server = item(
            .mcp, "db", .disabledMcpjsonServers, key: "disabledMcpjsonServers: db", enabled: false,
            enabledBy: "disabledMcpServers")
        let text = "{\"projects\":{\"/p\":{\"disabledMcpServers\":[\"db\"]}}}"
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem(["/h/.claude.json": text]))
        let change = try planner.setEnabled(server, enabled: true, writeScope: local, activeProject: "/p")
        #expect(change.edits.first?.file == "/h/.claude.json")
        #expect(String(decoding: try #require(change.edits.first).after, as: UTF8.self) == "{\"projects\":{\"/p\":{}}}")
    }

    @Test("An MCP change says it is per project")
    func perProjectWarning() throws {
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([:]))
        let change = try planner.setEnabled(mcp, enabled: false, writeScope: local, activeProject: "/p")
        #expect(change.warnings.contains { $0.contains("/p") })
    }

    @Test("A user server needs a project to be disabled in")
    func userServerNeedsProject() {
        let server = item(.mcp, "github", .disabledMcpServers, key: "projects[<path>].disabledMcpServers", projectPath: nil)
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([:]))
        #expect(throws: PlanError.self) {
            try planner.setEnabled(server, enabled: false, writeScope: user, activeProject: nil)
        }
    }

    @Test("Refused: unknown control, no toggle, no native switch, broken file")
    func refusals() {
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([local.file: "{\"a\":1,}"]))
        let good = Planner(environment: env, fileSystem: MemoryFileSystem([:]))
        let unknown = item(.skills, "s", .skillOverrides, key: "skillOverrides[\"s\"]", status: .unknown)
        let managed = item(.skills, "s", .skillOverrides, key: "skillOverrides[\"s\"]", ownership: .managed)
        let fromPlugin = item(.skills, "kit:s", .parentPlugin, key: "enabledPlugins[\"kit@m\"]", ownership: .plugin)
        let hook = item(.hooks, "h", .hookStash, key: "stash")
        for refused in [unknown, managed, fromPlugin, hook] {
            #expect(throws: PlanError.self) {
                try good.setEnabled(refused, enabled: false, writeScope: local, activeProject: "/p")
            }
        }
        #expect(throws: PlanError.self) {
            try planner.setEnabled(skill, enabled: false, writeScope: local, activeProject: "/p")
        }
    }

    @Test("Several changes to one file make one edit, each on top of the last")
    func batch() throws {
        let planner = Planner(environment: env, fileSystem: MemoryFileSystem([local.file: "{}\n"]))
        let changes = try planner.setEnabled(
            [(skill, false), (agent, false)], writeScope: local, activeProject: "/p")
        #expect(changes.count == 2)
        #expect(changes[0].edits.first?.before == Data("{}\n".utf8))
        #expect(changes[1].edits.first?.before == changes[0].edits.first?.after)
        let json = try JSONValue.parse(try #require(changes[1].edits.first).after)
        #expect(json["skillOverrides"]?["plan-review"] == .string("off"))
        #expect(json["permissions"]?["deny"]?.arrayValue == [.string("Agent(nest-reviewer)")])
    }
}
