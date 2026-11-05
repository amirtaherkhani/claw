import Foundation
import Testing

@testable import ClawCore

private let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
private let user = WriteScope(scope: .user, file: "/h/.claude/settings.json")
private let project = WriteScope(scope: .project, file: "/p/.claude/settings.json")
private let local = WriteScope(scope: .local, file: "/p/.claude/settings.local.json")
private let managed = "/managed/managed-settings.json"

private func item(
    _ concept: Concept, _ name: String, _ mechanism: ControlMechanism, key: String, enabled: Bool = true,
    location: String = "/p/x"
) -> Item {
    Item(
        concept: concept, key: name, name: name, description: "", scope: .project, projectPath: "/p",
        classification: Classification(ownership: .personal, rule: "T", evidence: []), location: location, enabled: enabled,
        control: ControlRef(mechanism: mechanism, key: key, status: .verified),
        capabilities: .forOwnership(.personal, isPlugin: concept == .plugins))
}

private let plugin = item(.plugins, "kit@m", .enabledPlugins, key: "enabledPlugins[\"kit@m\"]")
private let offPlugin = item(.plugins, "kit@m", .enabledPlugins, key: "enabledPlugins[\"kit@m\"]", enabled: false)
private let skill = item(.skills, "plan", .skillOverrides, key: "skillOverrides[\"plan\"]")
private let offSkill = item(.skills, "plan", .skillOverrides, key: "skillOverrides[\"plan\"]", enabled: false)
private let offAgent = item(.agents, "rev", .permissionsDeny, key: "permissions.deny: Agent(rev)", enabled: false)
private let offRule = item(
    .rules, "r.md", .claudeMdExcludes, key: "claudeMdExcludes: /p/r.md", enabled: false, location: "/p/r.md")
private let offServer = item(.mcp, "db", .disabledMcpjsonServers, key: "disabledMcpjsonServers: db", enabled: false)

private func planner(_ files: [String: String]) -> Planner {
    Planner(environment: env, fileSystem: MemoryFileSystem(files))
}

@Suite("Planner: overrides")
struct OverrideTests {
    @Test("A higher scope that enables a plugin defeats a disable, in Claude Code's words")
    func pluginStillLoads() throws {
        let files = [project.file: #"{"enabledPlugins":{"kit@m":true}}"#]
        let change = try planner(files).setEnabled(plugin, enabled: false, writeScope: user, activeProject: "/p")
        #expect(change.warnings == ["Disabled in user settings but still loads: project settings enable it"])
    }

    @Test("A higher scope that disables a plugin defeats an enable")
    func pluginStaysOff() throws {
        let files = [local.file: #"{"enabledPlugins":{"kit@m":false}}"#]
        let change = try planner(files).setEnabled(offPlugin, enabled: true, writeScope: project, activeProject: "/p")
        #expect(change.warnings == ["Enabled in project settings but stays off: local settings disable it"])
    }

    @Test("A lower or agreeing scope gives no warning")
    func noWarning() throws {
        let lower = [user.file: #"{"enabledPlugins":{"kit@m":true}}"#]
        #expect(try planner(lower).setEnabled(plugin, enabled: false, writeScope: local, activeProject: "/p").warnings.isEmpty)
        let agreeing = [local.file: #"{"enabledPlugins":{"kit@m":false}}"#]
        #expect(try planner(agreeing).setEnabled(plugin, enabled: false, writeScope: user, activeProject: "/p").warnings.isEmpty)
    }

    @Test("The highest scope that disagrees is the one named")
    func highestNamed() throws {
        let files = [
            project.file: #"{"enabledPlugins":{"kit@m":false}}"#, local.file: #"{"enabledPlugins":{"kit@m":true}}"#,
        ]
        let change = try planner(files).setEnabled(plugin, enabled: false, writeScope: user, activeProject: "/p")
        #expect(change.warnings == ["Disabled in user settings but still loads: local settings enable it"])
    }

    @Test("Skill overrides follow the same rule, per name [V S2]")
    func skills() throws {
        let on = [local.file: #"{"skillOverrides":{"plan":"on"}}"#]
        let off = try planner(on).setEnabled(skill, enabled: false, writeScope: user, activeProject: "/p")
        #expect(off.warnings == ["Disabled in user settings but still loads: local settings enable it"])
        let disabled = [local.file: #"{"skillOverrides":{"plan":"off"}}"#]
        let enabled = try planner(disabled).setEnabled(offSkill, enabled: true, writeScope: user, activeProject: "/p")
        #expect(enabled.warnings == ["Enabled in user settings but stays off: local settings disable it"])
        let other = [local.file: #"{"skillOverrides":{"another":"on"}}"#]
        #expect(try planner(other).setEnabled(skill, enabled: false, writeScope: user, activeProject: "/p").warnings.isEmpty)
    }

    @Test(
        "Lists add up across scopes: any other file keeps the item off",
        arguments: [
            (offAgent, #"{"permissions":{"deny":["Agent(rev)"]}}"#),
            (offRule, #"{"claudeMdExcludes":["/p/r.md"]}"#),
            (offServer, #"{"disabledMcpjsonServers":["db"]}"#),
        ])
    func lists(source: Item, text: String) throws {
        let lower = try planner([user.file: text]).setEnabled(source, enabled: true, writeScope: local, activeProject: "/p")
        #expect(lower.warnings == ["Enabled in local settings but stays off: user settings disable it"])
        let same = try planner([local.file: text]).setEnabled(source, enabled: true, writeScope: local, activeProject: "/p")
        #expect(same.warnings.isEmpty)
    }

    @Test("Disabling through a list needs no warning: disabled wins [V S7]")
    func disableInList() throws {
        let server = item(.mcp, "db", .disabledMcpjsonServers, key: "disabledMcpjsonServers: db")
        let files = [local.file: #"{"enabledMcpjsonServers":["db"]}"#]
        #expect(try planner(files).setEnabled(server, enabled: false, writeScope: user, activeProject: "/p").warnings.isEmpty)
        let already = [user.file: #"{"disabledMcpjsonServers":["db"]}"#]
        #expect(try planner(already).setEnabled(server, enabled: false, writeScope: local, activeProject: "/p").warnings.isEmpty)
    }

    @Test("Managed settings refuse, whichever way they point")
    func managedRefuses() {
        let required = [managed: #"{"enabledPlugins":{"kit@m":true}}"#]
        #expect(throws: PlanError.self) {
            try planner(required).setEnabled(plugin, enabled: false, writeScope: local, activeProject: "/p")
        }
        let blocked = [managed: #"{"enabledPlugins":{"kit@m":false}}"#]
        #expect(throws: PlanError.self) {
            try planner(blocked).setEnabled(offPlugin, enabled: true, writeScope: local, activeProject: "/p")
        }
        let denied = [managed: #"{"permissions":{"deny":["Agent(rev)"]}}"#]
        #expect(throws: PlanError.self) {
            try planner(denied).setEnabled(offAgent, enabled: true, writeScope: local, activeProject: "/p")
        }
    }

    @Test("Managed settings that agree change nothing")
    func managedAgrees() throws {
        let files = [managed: #"{"enabledPlugins":{"kit@m":true}}"#]
        let change = try planner(files).setEnabled(offPlugin, enabled: true, writeScope: local, activeProject: "/p")
        #expect(change.warnings.isEmpty)
    }

    @Test("A broken settings file in another scope is skipped, not fatal")
    func brokenLayer() throws {
        let files = [project.file: "{broken"]
        #expect(try planner(files).setEnabled(plugin, enabled: false, writeScope: user, activeProject: "/p").warnings.isEmpty)
    }

    @Test("Each change in a batch sees the ones before it")
    func batch() throws {
        let files = [local.file: #"{"enabledPlugins":{"kit@m":true}}"#]
        let changes = try planner(files).setEnabled(
            [(plugin, false)], writeScope: local, activeProject: "/p")
        #expect(changes[0].warnings.isEmpty)
    }
}
