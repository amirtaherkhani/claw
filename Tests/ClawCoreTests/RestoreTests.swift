import Foundation
import Testing

@testable import ClawCore

private final class Home: @unchecked Sendable {
    let path: String
    let env: ClaudeEnvironment
    let settings: String
    let command: String
    let skill: String

    static let settingsText = "{\n    \"enabledPlugins\": {\n        \"kit@m\": true\n    },\n    \"unknown\": [1, 2]\n}\n"

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        path = url.resolvingSymlinksInPath().path
        env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [])
        settings = env.userSettingsFile
        command = joinPath(env.configDir, "commands/old.md")
        skill = joinPath(env.configDir, "skills/tool")
        try FileManager.default.createDirectory(atPath: joinPath(env.configDir, "commands"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: joinPath(skill, "scripts"), withIntermediateDirectories: true)
        try put(settings, Self.settingsText)
        try put(command, "command body", mode: 0o640)
        try put(joinPath(skill, "SKILL.md"), "skill body", mode: 0o644)
        try put(joinPath(skill, "scripts/run.sh"), "#!/bin/sh\n", mode: 0o755)
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    func put(_ file: String, _ text: String, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: file))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file)
    }
    func read(_ file: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
    }
    func mode(_ file: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int)
    }

    var store: BackupStore { BackupStore(root: joinPath(path, ".claude.bak")) }
    var stash: HookStash { HookStash(root: joinPath(path, "stash")) }
    var planner: Planner { Planner(environment: env, fileSystem: LocalFileSystem()) }
    var restorer: Restorer { Restorer(store: store, stash: stash) }
    var user: WriteScope { WriteScope(scope: .user, file: settings) }

    func pipeline(fault: @escaping @Sendable (ApplyStep) throws -> Void = { _ in }) -> ApplyPipeline {
        ApplyPipeline(
            environment: env, store: store, stash: stash, cli: nil, appVersion: "0.1.0", claudeVersion: nil, fault: fault)
    }

    func item(_ concept: Concept, _ name: String, _ mechanism: ControlMechanism, key: String, location: String) -> Item {
        Item(
            concept: concept, key: name, name: name, description: "", scope: .user,
            classification: Classification(ownership: .personal, rule: "T", evidence: []), location: location, enabled: true,
            control: ControlRef(mechanism: mechanism, key: key, status: .verified),
            capabilities: .forOwnership(.personal, isPlugin: concept == .plugins))
    }

    var plugin: Item { item(.plugins, "kit@m", .enabledPlugins, key: "enabledPlugins[\"kit@m\"]", location: "/x") }
    var oldCommand: Item { item(.commands, "/old", .skillOverrides, key: "k", location: command) }
    var oldSkill: Item { item(.skills, "tool", .skillOverrides, key: "k", location: skill) }

    /// One edit, one removed file, one removed folder.
    func applyEverything(date: Date = Date(timeIntervalSince1970: 1_793_865_245)) async throws -> ApplyResult {
        let changes = [
            try planner.setEnabled(plugin, enabled: false, writeScope: user, activeProject: nil),
            try planner.remove(oldCommand), try planner.remove(oldSkill),
        ]
        return try await pipeline().apply(changes, title: "Everything", date: date)
    }

    func expectOriginal() throws {
        #expect(try read(settings) == Self.settingsText)
        #expect(try read(command) == "command body")
        #expect(try mode(command) == 0o640)
        #expect(try read(joinPath(skill, "SKILL.md")) == "skill body")
        #expect(try read(joinPath(skill, "scripts/run.sh")) == "#!/bin/sh\n")
        #expect(try mode(joinPath(skill, "scripts/run.sh")) == 0o755)
        #expect(try mode(joinPath(skill, "scripts")) == 0o755)
    }
}

@Suite("Restore")
struct RestoreTests {
    @Test("Apply then restore returns byte-identical files, modes included")
    func roundTrip() async throws {
        let home = try Home()
        let applied = try await home.applyEverything()
        #expect(applied.status == .applied)
        #expect(!FileManager.default.fileExists(atPath: home.command))

        let plan = try home.restorer.plan(id: applied.backupId)
        #expect(plan.conflicts.isEmpty)
        let result = try await home.pipeline().apply(
            plan.changes, title: "Restore", date: Date(timeIntervalSince1970: 1_793_865_300))
        #expect(result.status == .applied, "\(result.failure ?? "")")
        try home.expectOriginal()
        #expect(try home.store.ids().count == 2)
        #expect(try home.store.history.entries().entries.map(\.title) == ["Everything", "Restore"])
    }

    @Test("The plan shows the diff: current bytes against the backup's")
    func planShowsDiff() async throws {
        let home = try Home()
        let applied = try await home.applyEverything()
        let plan = try home.restorer.plan(id: applied.backupId)
        let edit = try #require(plan.changes.flatMap(\.edits).first { $0.file == home.settings })
        #expect(String(decoding: try #require(edit.before), as: UTF8.self).contains("\"kit@m\": false"))
        #expect(String(decoding: edit.after, as: UTF8.self) == Home.settingsText)
        #expect(plan.files.contains(home.command))
        #expect(plan.files.contains(joinPath(home.skill, "scripts/run.sh")))
    }

    @Test("A file the apply created is moved aside, not deleted")
    func createdFile() async throws {
        let home = try Home()
        let fresh = joinPath(home.path, "p/.claude/settings.local.json")
        try FileManager.default.createDirectory(
            atPath: (fresh as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let skill = home.item(.skills, "s", .skillOverrides, key: "skillOverrides[\"s\"]", location: "/x")
        let scope = WriteScope(scope: .local, file: fresh)
        let change = try home.planner.setEnabled(skill, enabled: false, writeScope: scope, activeProject: nil)
        let applied = try await home.pipeline().apply([change], title: "t")
        #expect(FileManager.default.fileExists(atPath: fresh))

        let plan = try home.restorer.plan(id: applied.backupId)
        #expect(try await home.pipeline().apply(plan.changes, title: "r").status == .applied)
        #expect(!FileManager.default.fileExists(atPath: fresh))
        let last = try #require(try home.store.ids().last)
        #expect(FileManager.default.fileExists(atPath: joinPath(home.store.root, last, "removed" + fresh)))
    }

    @Test("A file changed after the backup is a conflict, left alone until accepted")
    func changedAfter() async throws {
        let home = try Home()
        let applied = try await home.applyEverything()
        try home.put(home.settings, "{\"theirs\": true}\n")

        let plan = try home.restorer.plan(id: applied.backupId)
        #expect(plan.conflicts.map(\.path) == [home.settings])
        #expect(!plan.isComplete)
        #expect(!plan.files.contains(home.settings))
        #expect(try await home.pipeline().apply(plan.changes, title: "r").status == .applied)
        #expect(try home.read(home.settings) == "{\"theirs\": true}\n")
        #expect(try home.read(home.command) == "command body")

        let accepted = try home.restorer.plan(id: applied.backupId, accept: [home.settings])
        #expect(accepted.isComplete)
        #expect(try await home.pipeline().apply(accepted.changes, title: "r2").status == .applied)
        #expect(try home.read(home.settings) == Home.settingsText)
    }

    @Test("Something now where a removed item was is a conflict too")
    func placeTaken() async throws {
        let home = try Home()
        let applied = try await home.applyEverything()
        try home.put(home.command, "new file in its place")
        let plan = try home.restorer.plan(id: applied.backupId)
        #expect(plan.conflicts.map(\.path) == [home.command])
        let accepted = try home.restorer.plan(id: applied.backupId, accept: [home.command])
        #expect(try await home.pipeline().apply(accepted.changes, title: "r").status == .applied)
        #expect(try home.read(home.command) == "command body")
        let last = try #require(try home.store.ids().last)
        #expect(try home.read(joinPath(home.store.root, last, "files" + home.command)) == "new file in its place")
    }

    @Test("Restoring twice: the second has nothing left to do")
    func twice() async throws {
        let home = try Home()
        let applied = try await home.applyEverything()
        let first = try home.restorer.plan(id: applied.backupId)
        _ = try await home.pipeline().apply(first.changes, title: "r")
        let second = try home.restorer.plan(id: applied.backupId)
        #expect(second.changes.allSatisfy { $0.edits.isEmpty && $0.moves.isEmpty })
        #expect(second.alreadyRestored.contains(home.settings))
        #expect(second.conflicts.isEmpty)
    }

    @Test("A restored hook comes out of the stash")
    func hook() async throws {
        let home = try Home()
        try home.put(home.settings, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/s.sh"}]}]}}"#)
        let original = try home.read(home.settings)
        let hook = Item(
            concept: .hooks, key: "h", name: "Stop · s.sh", description: "", scope: .user,
            classification: Classification(ownership: .personal, rule: "T", evidence: []),
            location: "\(home.settings) › hooks.Stop[0].hooks[0]", enabled: true,
            control: ControlRef(mechanism: .hookStash, key: "stash", status: .verified),
            capabilities: Capabilities(edit: true, toggle: true, remove: true, removeLabel: "Remove entry", reason: nil))
        let off = try home.planner.setEnabled(hook, enabled: false, writeScope: nil, activeProject: nil)
        let applied = try await home.pipeline().apply([off], title: "t")
        #expect(try home.stash.entries().count == 1)

        let plan = try home.restorer.plan(id: applied.backupId)
        #expect(try await home.pipeline().apply(plan.changes, title: "r").status == .applied)
        #expect(try home.read(home.settings) == original)
        #expect(try home.stash.entries().isEmpty)
    }

    @Test("Only a finished apply can be restored")
    func notApplied() async throws {
        let home = try Home()
        var session = try home.store.start(appVersion: "1", claudeVersion: nil, operations: [])
        #expect(throws: BackupError.self) { try home.restorer.plan(id: session.manifest.id) }
        try session.finish(.rolledBack)
        #expect(throws: BackupError.self) { try home.restorer.plan(id: session.manifest.id) }
        #expect(throws: BackupError.self) { try home.restorer.plan(id: "nope") }
    }

    @Test("A fault at any step of a restore leaves the files as they were", arguments: ApplyStep.allCases)
    func faultDuringRestore(step: ApplyStep) async throws {
        let home = try Home()
        let applied = try await home.applyEverything()
        let afterApply = try home.read(home.settings)
        let plan = try home.restorer.plan(id: applied.backupId)
        struct Boom: Error {}
        let result = try await home.pipeline { if $0 == step { throw Boom() } }.apply(plan.changes, title: "r")
        #expect(result.status == .rolledBack)
        #expect(try home.read(home.settings) == afterApply)
        #expect(!FileManager.default.fileExists(atPath: home.command))
        #expect(!FileManager.default.fileExists(atPath: joinPath(home.skill, "SKILL.md")))
    }

    @Test("A moved link is not followed, and is reported")
    func link() async throws {
        let home = try Home()
        let link = joinPath(home.env.configDir, "commands/link.md")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home.command)
        let item = home.item(.commands, "/link", .skillOverrides, key: "k", location: link)
        let applied = try await home.pipeline().apply([try home.planner.remove(item)], title: "t")
        let plan = try home.restorer.plan(id: applied.backupId)
        #expect(plan.conflicts.map(\.path) == [link])
        #expect(plan.conflicts.first?.reason.contains("link") == true)
    }
}
