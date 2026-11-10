import Foundation
import Testing

@testable import ClawCore

private final class Setup: @unchecked Sendable {
    let path: String
    let env: ClaudeEnvironment
    let settings: String
    let command: String
    static let settingsText = "{\n    \"theme\": \"dark\"\n}\n"

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        path = url.resolvingSymlinksInPath().path
        env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [])
        settings = env.userSettingsFile
        command = joinPath(env.configDir, "commands/old.md")
        try FileManager.default.createDirectory(atPath: joinPath(env.configDir, "commands"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: joinPath(env.configDir, "skills/tool"), withIntermediateDirectories: true)
        try put(settings, Self.settingsText)
        try put(command, "---\ndescription: old\n---\nbody\n")
        try put(joinPath(env.configDir, "skills/tool/SKILL.md"), "---\nname: tool\ndescription: a tool\n---\nbody\n")
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    func put(_ file: String, _ text: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
    }
    func read(_ file: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
    }

    func commands() throws -> WriteCommands {
        let env = self.env
        return WriteCommands(
            environment: env, fileSystem: LocalFileSystem(), store: try BackupStore(environment: env),
            stash: HookStash(environment: env), cli: nil, appVersion: "0.1.0", claudeVersion: nil,
            scan: { await ConfigScanner(environment: env, cli: nil).scan() })
    }
}

@Suite("Write commands: plan, apply, restore, history")
struct WriteCommandsTests {
    @Test("plan shows the diff and writes nothing")
    func planWritesNothing() async throws {
        let setup = try Setup()
        let result = await (try setup.commands()).plan(ChangeRequest(action: .disable, selector: "tool"))
        #expect(result.exitCode == 0, "\(result.output)")
        #expect(result.output.contains("skillOverrides"))
        #expect(result.output.contains("+ "))
        #expect(try setup.read(setup.settings) == Setup.settingsText)
        #expect(!FileManager.default.fileExists(atPath: joinPath(setup.path, ".claude.bak")))
    }

    @Test("apply --dry-run prints exactly what plan prints, and writes nothing")
    func dryRunEqualsPlan() async throws {
        let setup = try Setup()
        let commands = try setup.commands()
        let request = ChangeRequest(action: .disable, selector: "tool")
        let plan = await commands.plan(request)
        let dry = await commands.apply(request, dryRun: true)
        #expect(dry == plan)
        #expect(try setup.read(setup.settings) == Setup.settingsText)
    }

    @Test("apply writes, and its output starts with the dry-run diff")
    func applyWrites() async throws {
        let setup = try Setup()
        let commands = try setup.commands()
        let request = ChangeRequest(action: .disable, selector: "tool")
        let plan = await commands.plan(request)
        let applied = await commands.apply(request, dryRun: false)
        #expect(applied.exitCode == 0, "\(applied.output)")
        #expect(applied.output.hasPrefix(plan.output))
        #expect(applied.output.contains("Backup "))
        let after = try setup.read(setup.settings)
        #expect(after.contains("skillOverrides") && after.contains("\"theme\": \"dark\""))
        let history = await commands.history()
        #expect(history.output.contains("applied"))
    }

    @Test("remove moves the file to the backup, restore brings it back")
    func removeThenRestore() async throws {
        let setup = try Setup()
        let commands = try setup.commands()
        let original = try setup.read(setup.command)
        let removed = await commands.apply(ChangeRequest(action: .remove, selector: "/old"), dryRun: false)
        #expect(removed.exitCode == 0, "\(removed.output)")
        #expect(!FileManager.default.fileExists(atPath: setup.command))

        let id = try #require(try BackupStore(environment: setup.env).ids().last)
        let dry = await commands.restore(id: id, accept: [], dryRun: true)
        #expect(dry.exitCode == 0, "\(dry.output)")
        #expect(!FileManager.default.fileExists(atPath: setup.command))

        let restored = await commands.restore(id: id, accept: [], dryRun: false)
        #expect(restored.exitCode == 0, "\(restored.output)")
        #expect(restored.output.hasPrefix(dry.output))
        #expect(try setup.read(setup.command) == original)
    }

    @Test("restore refuses while a file changed after the backup, until it is accepted by path")
    func restoreConflict() async throws {
        let setup = try Setup()
        let commands = try setup.commands()
        _ = await commands.apply(ChangeRequest(action: .disable, selector: "tool"), dryRun: false)
        let id = try #require(try BackupStore(environment: setup.env).ids().last)
        try setup.put(setup.settings, "{\"theirs\": true}\n")

        let refused = await commands.restore(id: id, accept: [], dryRun: false)
        #expect(refused.exitCode == 2)
        #expect(refused.output.contains(setup.settings) && refused.output.contains("--accept"))
        #expect(try setup.read(setup.settings) == "{\"theirs\": true}\n")

        let accepted = await commands.restore(id: id, accept: [setup.settings], dryRun: false)
        #expect(accepted.exitCode == 0, "\(accepted.output)")
        #expect(try setup.read(setup.settings) == Setup.settingsText)
    }

    @Test("unknown or ambiguous items and unknown backups exit with 2 and change nothing")
    func errors() async throws {
        let setup = try Setup()
        try FileManager.default.createDirectory(
            atPath: joinPath(setup.env.configDir, "agents"), withIntermediateDirectories: true)
        try setup.put(joinPath(setup.env.configDir, "agents/tool.md"), "---\nname: tool\ndescription: x\n---\nbody\n")
        let commands = try setup.commands()
        let none = await commands.plan(ChangeRequest(action: .disable, selector: "does-not-exist"))
        #expect(none.exitCode == 2 && none.output.contains("no item"))
        let many = await commands.plan(ChangeRequest(action: .disable, selector: "tool"))
        #expect(many.exitCode == 2 && many.output.contains("more than one"))
        let backup = await commands.restore(id: "nope", accept: [], dryRun: false)
        #expect(backup.exitCode == 2)
        #expect(try setup.read(setup.settings) == Setup.settingsText)
    }

    @Test("project scopes need a project, managed is refused")
    func scopes() async throws {
        let setup = try Setup()
        let commands = try setup.commands()
        let project = await commands.plan(ChangeRequest(action: .disable, selector: "tool", scope: .project))
        #expect(project.exitCode == 2 && project.output.contains("--project"))
        let managed = await commands.plan(ChangeRequest(action: .disable, selector: "tool", scope: .managed))
        #expect(managed.exitCode == 2)
    }

    @Test("history is empty before any change")
    func emptyHistory() async throws {
        let setup = try Setup()
        let result = await (try setup.commands()).history()
        #expect(result.exitCode == 0 && result.output.contains("No changes"))
    }
}
