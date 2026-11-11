import Foundation
import Testing

@testable import ClawCore

/// Claude Code's own `claude` command makes every change it has a command for (`CommandCatalog`); Claw makes the
/// rest, and all of them when `claude` is not found. For a `claude` change, Claw still works out what it should
/// write, shows it and checks it afterwards.
@Suite("Command routes")
struct CommandRouteTests {
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: [])
    static let settings = "/h/.claude/settings.json"
    static let user = WriteScope(scope: .user, file: settings)

    static func item(
        _ concept: Concept, _ name: String, _ mechanism: ControlMechanism, key: String, enabled: Bool = true,
        ownership: Ownership = .personal
    ) -> Item {
        Item(
            concept: concept, key: name, name: name, description: "", scope: .user,
            classification: Classification(ownership: ownership, rule: "T", evidence: []), location: "/x",
            enabled: enabled, control: ControlRef(mechanism: mechanism, key: key, status: .verified),
            capabilities: .forOwnership(ownership, isPlugin: concept == .plugins))
    }

    static let plugin = item(.plugins, "kit@m", .enabledPlugins, key: "enabledPlugins[\"kit@m\"]")
    static let skill = item(.skills, "tidy", .skillOverrides, key: "skillOverrides[\"tidy\"]")

    @Test("A template fills the id, the name and the scope, and --keep-data only when data is kept")
    func template() {
        let uninstall = CommandCatalog.standard.command(ControlAction(.plugins, .remove), scope: .project)
        #expect(
            uninstall?.argv(id: "kit@m", name: "kit", scope: .project)
                == ["plugin", "uninstall", "kit@m", "--scope", "project", "--keep-data"])
        #expect(
            uninstall?.argv(id: "kit@m", name: "kit", scope: .user, keepData: false)
                == ["plugin", "uninstall", "kit@m", "--scope", "user"])
        #expect(CommandCatalog.standard.command(ControlAction(.skills, .disable), scope: .user) == nil)
        #expect(CommandCatalog.standard.command(ControlAction(.plugins, .disable), scope: .managed) == nil)
    }

    @Test("With claude, a plugin is turned off by claude plugin disable; Claw writes nothing and expects the key")
    func pluginByClaude() throws {
        let fs = MemoryFileSystem([Self.settings: "{\n  \"enabledPlugins\": {\n    \"kit@m\": true\n  }\n}\n"])
        let planner = Planner(environment: Self.env, fileSystem: fs, commands: .standard)
        let change = try planner.setEnabled(Self.plugin, enabled: false, writeScope: Self.user, activeProject: nil)
        #expect(change.edits.isEmpty)
        #expect(change.cli == [CliStep(argv: ["plugin", "disable", "kit@m", "--scope", "user"], workingDirectory: nil)])
        #expect(change.cliTouches == [Self.settings])
        #expect(change.preview.count == 1)
        #expect(change.expected == [ExpectedValue(file: Self.settings, path: ["enabledPlugins", "kit@m"], value: .bool(false))])
        #expect(change.pluginCheck?.enabled == false)
    }

    @Test("In a project scope the command runs in the project folder")
    func projectScope() throws {
        let project = WriteScope(scope: .project, file: "/p/.claude/settings.json")
        let planner = Planner(environment: Self.env, fileSystem: MemoryFileSystem([:]), commands: .standard)
        let change = try planner.setEnabled(Self.plugin, enabled: true, writeScope: project, activeProject: "/p")
        #expect(change.cli == [CliStep(argv: ["plugin", "enable", "kit@m", "--scope", "project"], workingDirectory: "/p")])
    }

    @Test("Without claude, or with no command for it, Claw edits the file itself")
    func clawEdits() throws {
        let fs = MemoryFileSystem([Self.settings: "{}\n"])
        let none = try Planner(environment: Self.env, fileSystem: fs, commands: .none)
            .setEnabled(Self.plugin, enabled: false, writeScope: Self.user, activeProject: nil)
        #expect(none.cli.isEmpty && none.edits.count == 1)
        let skill = try Planner(environment: Self.env, fileSystem: fs, commands: .standard)
            .setEnabled(Self.skill, enabled: false, writeScope: Self.user, activeProject: nil)
        #expect(skill.cli.isEmpty && skill.edits.count == 1)
    }

    @Test("A command added to the catalog moves that action to claude, with no other change")
    func editable() throws {
        var catalog = CommandCatalog.standard
        catalog.commands[ControlAction(.skills, .disable)] = ClaudeCommand(
            ["skill", "disable", "{name}", "--scope", "{scope}"], scopes: [.user])
        let change = try Planner(environment: Self.env, fileSystem: MemoryFileSystem([:]), commands: catalog)
            .setEnabled(Self.skill, enabled: false, writeScope: Self.user, activeProject: nil)
        #expect(change.cli.first?.argv == ["skill", "disable", "tidy", "--scope", "user"])
        #expect(change.expected == [ExpectedValue(file: Self.settings, path: ["skillOverrides", "tidy"], value: .string("off"))])
    }

    @Test("The item detail names claude's command or Claw's own edit for each change")
    func routes() {
        let plugin = CommandCatalog.standard.routes(for: Self.plugin, scope: .user, claudeAvailable: true)
        #expect(plugin.map(\.0) == [.disable, .remove])
        #expect(plugin.first?.1 == .claude("claude plugin disable kit@m --scope user"))
        #expect(plugin.last?.1 == .claude("claude plugin uninstall kit@m --scope user --keep-data"))
        let noClaude = CommandCatalog.standard.routes(for: Self.plugin, scope: .user, claudeAvailable: false)
        #expect(
            noClaude.first?.1
                == .claw(
                    "Claw sets enabledPlugins in settings",
                    reason: "The claude command was not found, so Claw does it itself."))
        let skill = CommandCatalog.standard.routes(for: Self.skill, scope: .user, claudeAvailable: true)
        #expect(
            skill.first?.1
                == .claw("Claw sets skillOverrides in settings", reason: "Claude Code has no command for this yet."))
        let orphan = Self.item(.plugins, "gone@m", .enabledPlugins, key: "k", ownership: .orphan)
        let gone = CommandCatalog.standard.routes(for: orphan, scope: .user, claudeAvailable: true)
        #expect(gone.allSatisfy { if case .claw = $0.1 { true } else { false } })
    }

    // MARK: Apply with a stand-in claude

    /// Does what `claude plugin disable` does to a settings file: rewrites it whole, keys reordered.
    struct RewritingClaude: CommandRunner {
        let file: String
        let obeys: Bool
        func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
            switch arguments.joined(separator: " ") {
            case "plugin disable kit@m --scope user":
                let now = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: file)))
                let next = obeys ? now.setting(["enabledPlugins", "kit@m"], to: .bool(false)) : now
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(next).write(to: URL(fileURLWithPath: file))
                return ok("")
            case "plugin list --json":
                return ok(#"[{"id":"kit@m","installPath":"/c","scope":"user","enabled":\#(obeys ? "false" : "true")}]"#)
            default:
                throw CommandError.notFound
            }
        }
    }

    func run(obeys: Bool) async throws -> (ApplyResult, String, String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = url.resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let env = ClaudeEnvironment(home: home, managedDir: joinPath(home, "managed"), projects: [])
        try FileManager.default.createDirectory(atPath: env.configDir, withIntermediateDirectories: true)
        let original = "{\n  \"theme\": \"dark\",\n  \"enabledPlugins\": {\n    \"kit@m\": true\n  }\n}\n"
        try Data(original.utf8).write(to: URL(fileURLWithPath: env.userSettingsFile))
        let scope = WriteScope(scope: .user, file: env.userSettingsFile)
        let planner = Planner(environment: env, fileSystem: LocalFileSystem(), commands: .standard)
        let results = planner.plan(
            [.setEnabled(Self.plugin, false), .setEnabled(Self.skill, false)], writeScope: scope, activeProject: nil)
        let changes = try results.map { try $0.get() }
        let pipeline = ApplyPipeline(
            environment: env, store: BackupStore(root: joinPath(home, ".claude.bak")),
            stash: HookStash(root: joinPath(home, "stash")),
            cli: ClaudeCLI(executable: "/bin/claude", runner: RewritingClaude(file: env.userSettingsFile, obeys: obeys)),
            appVersion: "0.1.0", claudeVersion: nil)
        let result = try await pipeline.apply(changes, title: "t")
        let after = String(decoding: try Data(contentsOf: URL(fileURLWithPath: env.userSettingsFile)), as: UTF8.self)
        return (result, after, original)
    }

    @Test("Claw's edit and claude's rewrite of one file both land, and the result is checked")
    func applyBoth() async throws {
        let (result, after, _) = try await run(obeys: true)
        #expect(result.status == .applied, "\(result.failure ?? "")")
        let final = try JSONValue.parse(Data(after.utf8))
        #expect(final["enabledPlugins"]?["kit@m"] == .bool(false))
        #expect(final["skillOverrides"]?["tidy"] == .string("off"))
        #expect(final["theme"] == .string("dark"))
    }

    @Test("A claude step that does not make its change is rolled back, with the file as it was")
    func applyChecked() async throws {
        let (result, after, original) = try await run(obeys: false)
        #expect(result.status == .rolledBack)
        #expect(result.failure?.contains("did not leave enabledPlugins.kit@m") == true)
        #expect(after == original)
    }
}
