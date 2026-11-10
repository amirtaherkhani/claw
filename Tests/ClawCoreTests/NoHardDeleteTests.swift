import Foundation
import Testing

@testable import ClawCore

/// NFR-SAFE: Claw never hard-deletes a user file (ROADMAP M2.13). Every destructive call of the write layer goes
/// through `Disk`; these tests watch it while applying, restoring, failing at every step and recovering.
///
/// The rule the guard checks:
/// - `unlink` only on Claw's own temporary files (`.<name>.<uuid>.tmp`).
/// - `rename` onto a path that exists only from such a temporary file: the atomic write, whose original the backup
///   kept first. Any other rename is a move to a free path, so nothing is lost.
final class DeleteGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String] = []

    var violations: [String] { lock.withLock { found } }

    static func isTemporary(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".tmp")
    }

    func observe(_ operation: Disk.Operation) {
        switch operation {
        case .unlink(let path):
            if !Self.isTemporary(path) { record("hard delete of \(path)") }
        case .rename(let from, let to):
            var info = stat()
            if lstat(to, &info) == 0, !Self.isTemporary(from) { record("rename of \(from) over existing \(to)") }
        }
    }

    private func record(_ text: String) { lock.withLock { found.append(text) } }

    /// Runs `body` with the guard watching every destructive call, also on the threads the pipeline starts.
    func watch<T>(_ body: () async throws -> T) async rethrows -> T {
        let observer: @Sendable (Disk.Operation) -> Void = { [self] in observe($0) }
        return try await Disk.$observer.withValue(observer, operation: body)
    }
}

private final class Scenario: @unchecked Sendable {
    let path: String
    let env: ClaudeEnvironment
    let settings: String
    let command: String
    let skill: String

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        path = url.resolvingSymlinksInPath().path
        env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [])
        settings = env.userSettingsFile
        command = joinPath(env.configDir, "commands/old.md")
        skill = joinPath(env.configDir, "skills/tool")
        try FileManager.default.createDirectory(atPath: joinPath(skill, "scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: joinPath(env.configDir, "commands"), withIntermediateDirectories: true)
        try put(
            settings,
            #"{"enabledPlugins":{"kit@m":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/s.sh"}]}]}}"#)
        try put(command, "command body")
        try put(joinPath(skill, "SKILL.md"), "skill body")
        try put(joinPath(skill, "scripts/run.sh"), "#!/bin/sh\n")
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    func put(_ file: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: file)) }

    var store: BackupStore { BackupStore(root: joinPath(path, ".claude.bak")) }
    var stash: HookStash { HookStash(root: joinPath(path, "stash")) }
    var planner: Planner { Planner(environment: env, fileSystem: LocalFileSystem()) }

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

    /// An edit, a removed file, a removed folder and a stashed hook.
    func changes() throws -> [PlannedChange] {
        let hook = Item(
            concept: .hooks, key: "h", name: "Stop · s.sh", description: "", scope: .user,
            classification: Classification(ownership: .personal, rule: "T", evidence: []),
            location: "\(settings) › hooks.Stop[0].hooks[0]", enabled: true,
            control: ControlRef(mechanism: .hookStash, key: "stash", status: .verified),
            capabilities: Capabilities(edit: true, toggle: true, remove: true, removeLabel: "Remove entry", reason: nil))
        let plugin = item(.plugins, "kit@m", .enabledPlugins, key: "enabledPlugins[\"kit@m\"]", location: "/x")
        let user = WriteScope(scope: .user, file: settings)
        return try planner.setEnabled([(plugin, false)], writeScope: user, activeProject: nil) + [
            try planner.remove(item(.commands, "/old", .skillOverrides, key: "k", location: command)),
            try planner.remove(item(.skills, "tool", .skillOverrides, key: "k", location: skill)),
        ] + [try planner.setEnabled(hook, enabled: false, writeScope: nil, activeProject: nil)]
    }
}

@Suite("No hard delete", .serialized)
struct NoHardDeleteTests {
    @Test("The guard itself catches a hard delete and an overwrite")
    func guardWorks() async throws {
        let scenario = try Scenario()
        let watcher = DeleteGuard()
        await watcher.watch {
            _ = Disk.unlink(scenario.command)
            _ = Disk.rename(joinPath(scenario.skill, "SKILL.md"), scenario.settings)
        }
        #expect(watcher.violations.count == 2)
        #expect(!FileManager.default.fileExists(atPath: scenario.command))
    }

    @Test("Apply then restore deletes nothing")
    func applyRestore() async throws {
        let scenario = try Scenario()
        let watcher = DeleteGuard()
        try await watcher.watch {
            let applied = try await scenario.pipeline().apply(try scenario.changes(), title: "t")
            #expect(applied.status == .applied, "\(applied.failure ?? "")")
            let plan = try Restorer(store: scenario.store, stash: scenario.stash).plan(id: applied.backupId)
            let restored = try await scenario.pipeline().apply(plan.changes, title: "r")
            #expect(restored.status == .applied, "\(restored.failure ?? "")")
        }
        #expect(watcher.violations.isEmpty, "\(watcher.violations)")
        #expect(FileManager.default.fileExists(atPath: joinPath(scenario.skill, "scripts/run.sh")))
    }

    @Test("A failure at any step, and its rollback, deletes nothing", arguments: ApplyStep.allCases)
    func failure(step: ApplyStep) async throws {
        let scenario = try Scenario()
        let watcher = DeleteGuard()
        struct Boom: Error {}
        try await watcher.watch {
            let result = try await scenario.pipeline { if $0 == step { throw Boom() } }.apply(
                try scenario.changes(), title: "t")
            #expect(result.status == .rolledBack)
        }
        #expect(watcher.violations.isEmpty, "\(watcher.violations)")
    }

    @Test("A crash at any step, and recovery, deletes nothing", arguments: ApplyStep.allCases)
    func crash(step: ApplyStep) async throws {
        let scenario = try Scenario()
        let watcher = DeleteGuard()
        try await watcher.watch {
            let pipeline = scenario.pipeline { if $0 == step { throw ApplyCrash() } }
            await #expect(throws: ApplyCrash.self) { try await pipeline.apply(try scenario.changes(), title: "t") }
            let id = try #require(try scenario.store.interrupted().first)
            _ = try scenario.store.rollBack(id: id, stash: scenario.stash)
        }
        #expect(watcher.violations.isEmpty, "\(watcher.violations)")
    }

    @Test("A restore that fails at any step deletes nothing", arguments: ApplyStep.allCases)
    func restoreFailure(step: ApplyStep) async throws {
        let scenario = try Scenario()
        let watcher = DeleteGuard()
        struct Boom: Error {}
        try await watcher.watch {
            let applied = try await scenario.pipeline().apply(try scenario.changes(), title: "t")
            let plan = try Restorer(store: scenario.store, stash: scenario.stash).plan(id: applied.backupId)
            _ = try await scenario.pipeline { if $0 == step { throw Boom() } }.apply(plan.changes, title: "r")
        }
        #expect(watcher.violations.isEmpty, "\(watcher.violations)")
    }

    /// The seam only helps if nothing goes around it.
    @Test("The write layer calls rename, unlink and removeItem only through Disk")
    func noBypass() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ClawCore")
        var offenders: [String] = []
        for folder in ["Write", "Plan", "Commands"] {
            let dir = sources.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                guard name != "Disk.swift" else { continue }
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let code = line.components(separatedBy: "//").first ?? ""
                    let raw = code.replacingOccurrences(of: "Disk.rename(", with: "").replacingOccurrences(
                        of: "Disk.unlink(", with: "")
                    if raw.contains("rename(") || raw.contains("unlink(") || raw.contains("removeItem")
                        || raw.contains("rmdir(")
                    {
                        offenders.append("\(folder)/\(name):\(number + 1)")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
