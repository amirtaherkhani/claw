import Foundation
import Testing

@testable import ClawCore

private final class Home: @unchecked Sendable {
    let path: String
    let env: ClaudeEnvironment
    let settings: String
    let claudeJson: String
    let command: String
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        path = url.resolvingSymlinksInPath().path
        env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [joinPath(path, "p")])
        settings = env.userSettingsFile
        claudeJson = env.claudeJsonFile
        command = joinPath(env.configDir, "commands/old.md")
        try FileManager.default.createDirectory(atPath: joinPath(env.configDir, "commands"), withIntermediateDirectories: true)
        try put(settings, Self.settingsText)
        try put(claudeJson, Self.claudeJsonText)
        try put(command, "body")
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    static let settingsText = """
        {
            "enabledPlugins": {
                "kit@m": true
            },
            "unknown": [1, 2]
        }

        """
    static let claudeJsonText = "{\n  \"projects\": {}\n}\n"

    func put(_ file: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: file)) }
    func read(_ file: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
    }
    var store: BackupStore { BackupStore(root: joinPath(path, ".claude.bak")) }
    var stash: HookStash { HookStash(root: joinPath(path, "stash")) }
    var fs: LocalFileSystem { LocalFileSystem() }
    var user: WriteScope { WriteScope(scope: .user, file: settings) }

    func item(_ concept: Concept, _ name: String, _ mechanism: ControlMechanism, key: String, location: String = "/x") -> Item {
        Item(
            concept: concept, key: name, name: name, description: "", scope: .user,
            classification: Classification(ownership: .personal, rule: "T", evidence: []), location: location, enabled: true,
            control: ControlRef(mechanism: mechanism, key: key, status: .verified),
            capabilities: .forOwnership(.personal, isPlugin: concept == .plugins))
    }

    var plugin: Item { item(.plugins, "kit@m", .enabledPlugins, key: "enabledPlugins[\"kit@m\"]") }
    var oldCommand: Item { item(.commands, "/old", .skillOverrides, key: "skillOverrides[\"old\"]", location: command) }

    /// One plugin edit and one file move.
    func changes() throws -> [PlannedChange] {
        let planner = Planner(environment: env, fileSystem: fs)
        return [
            try planner.setEnabled(plugin, enabled: false, writeScope: user, activeProject: nil),
            try planner.remove(oldCommand),
        ]
    }

    func pipeline(
        runner: any CommandRunner = FakeRunner(responses: [
            "plugin list --json": ok(#"[{"id":"kit@m","installPath":"/c","scope":"user","enabled":false}]"#)
        ]),
        fault: @escaping @Sendable (ApplyStep) throws -> Void = { _ in }
    ) -> ApplyPipeline {
        ApplyPipeline(
            environment: env, store: store, stash: stash, cli: ClaudeCLI(executable: "/bin/claude", runner: runner),
            appVersion: "0.1.0", claudeVersion: "2.1.316", fault: fault)
    }

    func expectOriginal() throws {
        #expect(try read(settings) == Self.settingsText)
        #expect(try read(claudeJson) == Self.claudeJsonText)
        #expect(try read(command) == "body")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.configDir).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }
}

private struct Boom: Error {}

@Suite("Apply")
struct ApplyTests {
    @Test("A good apply writes, moves, verifies and records")
    func success() async throws {
        let home = try Home()
        let result = try await home.pipeline().apply(try home.changes(), title: "Two changes")
        #expect(result.status == .applied, "\(result.failure ?? "")")
        #expect(result.failure == nil)
        #expect(try home.read(home.settings).contains("\"kit@m\": false"))
        #expect(try home.read(home.settings).contains("\"unknown\": [1, 2]"))
        #expect(!FileManager.default.fileExists(atPath: home.command))
        let manifest = try home.store.manifest(id: result.backupId)
        #expect(manifest.status == .applied)
        #expect(manifest.claudeCode.version == "2.1.316")
        #expect(manifest.files.first?.sha256Before == SHA256.hex(Data(Home.settingsText.utf8)))
        #expect(manifest.files.first?.sha256After == (try AtomicWrite.sha256(ofFile: home.settings)))
        #expect(manifest.moves.first?.from == home.command)
        let entry = try #require(try home.store.history.entries().entries.last)
        #expect(entry.title == "Two changes")
        #expect(entry.result == .applied)
        #expect(entry.files.contains(home.settings))
    }

    @Test("Two changes to one file are one write from the first before to the last after")
    func merged() async throws {
        let home = try Home()
        let planner = Planner(environment: home.env, fileSystem: home.fs)
        let skill = home.item(.skills, "s", .skillOverrides, key: "skillOverrides[\"s\"]")
        let changes = try planner.setEnabled([(home.plugin, false), (skill, false)], writeScope: home.user, activeProject: nil)
        let result = try await home.pipeline().apply(changes, title: "t")
        #expect(result.status == .applied)
        let json = try JSONValue.parse(Data(try home.read(home.settings).utf8))
        #expect(json["skillOverrides"]?["s"]?.stringValue == "off")
        #expect(try home.store.manifest(id: result.backupId).files.count == 1)
    }

    @Test("A fault at any step leaves the old files", arguments: ApplyStep.allCases)
    func faultRollsBack(step: ApplyStep) async throws {
        let home = try Home()
        let pipeline = home.pipeline { if $0 == step { throw Boom() } }
        let result = try await pipeline.apply(try home.changes(), title: "t")
        #expect(result.status == .rolledBack)
        #expect(result.failure != nil)
        try home.expectOriginal()
        #expect(try home.store.interrupted().isEmpty)
        #expect(try home.store.history.entries().entries.last?.result == .rolledBack)
    }

    @Test("A crash at any step is recovered at the next start", arguments: ApplyStep.allCases)
    func crashRecovers(step: ApplyStep) async throws {
        let home = try Home()
        let pipeline = home.pipeline { if $0 == step { throw ApplyCrash() } }
        await #expect(throws: ApplyCrash.self) { try await pipeline.apply(try home.changes(), title: "t") }
        let id = try #require(try home.store.interrupted().first)
        #expect(try home.store.rollBack(id: id).kept.isEmpty)
        try home.expectOriginal()
    }

    @Test("A file changed since planning stops everything, with no backup")
    func stale() async throws {
        let home = try Home()
        let changes = try home.changes()
        try home.put(home.settings, "{}\n")
        await #expect(throws: StaleFileError.self) { try await home.pipeline().apply(changes, title: "t") }
        #expect(try home.read(home.settings) == "{}\n")
        #expect(try home.store.ids().isEmpty)
        #expect(FileManager.default.fileExists(atPath: home.command))
    }

    @Test("A failed CLI step undoes what ran before it, and what the CLI itself wrote")
    func cliFailure() async throws {
        struct Scribble: CommandRunner {
            let file: String
            func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
                try Data("{\"half\": true}\n".utf8).write(to: URL(fileURLWithPath: file))
                return CommandResult(exitCode: 1, stdout: Data(), stderr: Data("token=secret-value".utf8))
            }
        }
        let home = try Home()
        let planner = Planner(environment: home.env, fileSystem: home.fs)
        let server = home.item(.mcp, "github", .disabledMcpServers, key: "k")
        let changes = [
            try planner.setEnabled(home.plugin, enabled: false, writeScope: home.user, activeProject: nil),
            try planner.remove(server),
        ]
        let result = try await home.pipeline(runner: Scribble(file: home.claudeJson)).apply(changes, title: "t")
        #expect(result.status == .rolledBack)
        #expect(!(result.failure ?? "").contains("secret-value"))
        try home.expectOriginal()
    }

    @Test("Claude Code disagreeing after the write rolls back")
    func verifyMismatch() async throws {
        let home = try Home()
        let runner = FakeRunner(responses: [
            "plugin list --json": ok(#"[{"id":"kit@m","installPath":"/c","scope":"user","enabled":true}]"#)
        ])
        let result = try await home.pipeline(runner: runner).apply(try home.changes(), title: "t")
        #expect(result.status == .rolledBack)
        #expect(result.failure?.contains("kit@m") == true)
        try home.expectOriginal()
    }

    @Test("A plugin an override keeps on is not a verify failure")
    func overrideWarned() async throws {
        let home = try Home()
        let project = joinPath(home.path, "p")
        try FileManager.default.createDirectory(atPath: joinPath(project, ".claude"), withIntermediateDirectories: true)
        try home.put(home.env.projectSettingsFile(project), #"{"enabledPlugins":{"kit@m":true}}"#)
        let change = try Planner(environment: home.env, fileSystem: home.fs)
            .setEnabled(home.plugin, enabled: false, writeScope: home.user, activeProject: project)
        #expect(!change.warnings.isEmpty)
        let runner = FakeRunner(responses: [
            "plugin list --json": ok(#"[{"id":"kit@m","installPath":"/c","scope":"user","enabled":true}]"#)
        ])
        #expect(try await home.pipeline(runner: runner).apply([change], title: "t").status == .applied)
    }

    @Test("With no CLI the apply still works, and says it could not ask Claude Code")
    func noCli() async throws {
        let home = try Home()
        let pipeline = ApplyPipeline(
            environment: home.env, store: home.store, stash: home.stash, cli: nil, appVersion: "1", claudeVersion: nil)
        let change = try Planner(environment: home.env, fileSystem: home.fs)
            .setEnabled(home.plugin, enabled: false, writeScope: home.user, activeProject: nil)
        let result = try await pipeline.apply([change], title: "t")
        #expect(result.status == .applied)
        #expect(!result.notes.isEmpty)
    }

    @Test("A CLI step with no CLI is refused before anything changes")
    func cliStepNoCli() async throws {
        let home = try Home()
        let pipeline = ApplyPipeline(
            environment: home.env, store: home.store, stash: home.stash, cli: nil, appVersion: "1", claudeVersion: nil)
        let change = try Planner(environment: home.env, fileSystem: home.fs)
            .remove(home.item(.mcp, "github", .disabledMcpServers, key: "k"))
        await #expect(throws: PlanError.self) { try await pipeline.apply([change], title: "t") }
        #expect(try home.store.ids().isEmpty)
    }

    @Test("A running Claude Code rewriting .claude.json: planned again, up to three times")
    func claudeJsonRetry() async throws {
        let home = try Home()
        let counter = Counter()
        let server = Item(
            concept: .mcp, key: "gh", name: "gh", description: "", scope: .project, projectPath: joinPath(home.path, "p"),
            classification: Classification(ownership: .personal, rule: "T", evidence: []), location: home.claudeJson,
            enabled: true, control: ControlRef(mechanism: .disabledMcpServers, key: "k", status: .verified),
            capabilities: .forOwnership(.personal, isPlugin: false))
        let claudeJson = home.claudeJson
        let plan: @Sendable () throws -> [PlannedChange] = {
            [
                try Planner(environment: home.env, fileSystem: LocalFileSystem()).setEnabled(
                    server, enabled: false, writeScope: nil, activeProject: nil)
            ]
        }
        let pipeline = home.pipeline {
            guard $0 == .originalsKept, counter.next() < 2 else { return }
            try Data("{\n  \"projects\": {},\n  \"numStartups\": \(counter.value)\n}\n".utf8).write(
                to: URL(fileURLWithPath: claudeJson))
        }
        let result = try await pipeline.apply(try plan(), title: "t", replan: plan)
        #expect(result.status == .applied)
        #expect(try home.read(claudeJson).contains("numStartups"))
        #expect(try home.read(claudeJson).contains("disabledMcpServers"))

        let always = home.pipeline {
            guard $0 == .originalsKept else { return }
            try Data("{\"tick\": \(counter.next())}\n".utf8).write(to: URL(fileURLWithPath: claudeJson))
        }
        let second = Item(
            concept: .mcp, key: "x", name: "other", description: "", scope: .project, projectPath: joinPath(home.path, "p"),
            classification: Classification(ownership: .personal, rule: "T", evidence: []), location: home.claudeJson,
            enabled: true, control: ControlRef(mechanism: .disabledMcpServers, key: "k", status: .verified),
            capabilities: .forOwnership(.personal, isPlugin: false))
        let replan: @Sendable () throws -> [PlannedChange] = {
            [
                try Planner(environment: home.env, fileSystem: LocalFileSystem()).setEnabled(
                    second, enabled: false, writeScope: nil, activeProject: nil)
            ]
        }
        let failed = try await always.apply(try replan(), title: "t", replan: replan)
        #expect(failed.status == .rolledBack)
        #expect(failed.failure?.contains("Close") == true)
    }

    @Test("A hook disabled goes into the stash; a restore takes it out")
    func hookStash() async throws {
        let home = try Home()
        try home.put(home.settings, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/s.sh"}]}]}}"#)
        let hook = Item(
            concept: .hooks, key: "h", name: "Stop · s.sh", description: "", scope: .user,
            classification: Classification(ownership: .personal, rule: "T", evidence: []),
            location: "\(home.settings) › hooks.Stop[0].hooks[0]", enabled: true,
            control: ControlRef(mechanism: .hookStash, key: "stash", status: .verified),
            capabilities: Capabilities(edit: true, toggle: true, remove: true, removeLabel: "Remove entry", reason: nil))
        let planner = Planner(environment: home.env, fileSystem: home.fs)
        let off = try planner.setEnabled(hook, enabled: false, writeScope: nil, activeProject: nil)
        #expect(try await home.pipeline().apply([off], title: "t").status == .applied)
        let entry = try #require(try home.stash.entries().first)
        #expect(!(try home.read(home.settings)).contains("s.sh"))

        let on = try planner.restore(entry)
        #expect(try await home.pipeline().apply([on], title: "t").status == .applied)
        #expect(try home.read(home.settings).contains("s.sh"))
        #expect(try home.stash.entries().isEmpty)
    }

    @Test("A fault after the stash was filled empties it again")
    func stashRollback() async throws {
        let home = try Home()
        try home.put(home.settings, #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/s.sh"}]}]}}"#)
        let hook = Item(
            concept: .hooks, key: "h", name: "Stop · s.sh", description: "", scope: .user,
            classification: Classification(ownership: .personal, rule: "T", evidence: []),
            location: "\(home.settings) › hooks.Stop[0].hooks[0]", enabled: true,
            control: ControlRef(mechanism: .hookStash, key: "stash", status: .verified),
            capabilities: Capabilities(edit: true, toggle: true, remove: true, removeLabel: "Remove entry", reason: nil))
        let off = try Planner(environment: home.env, fileSystem: home.fs)
            .setEnabled(hook, enabled: false, writeScope: nil, activeProject: nil)
        let pipeline = home.pipeline { if $0 == .filesWritten { throw Boom() } }
        #expect(try await pipeline.apply([off], title: "t").status == .rolledBack)
        #expect(try home.stash.entries().isEmpty)
        #expect(try home.read(home.settings).contains("s.sh"))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int {
        lock.withLock {
            count += 1
            return count - 1
        }
    }
}
