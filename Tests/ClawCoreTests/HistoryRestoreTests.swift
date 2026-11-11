import Foundation
import Testing

@testable import ClawCore

/// M4.4: History lists every Apply with its backup, and Restore puts the backed-up bytes back through the same
/// pipeline (its own backup first). A file changed after the backup is shown and left alone until accepted.
@Suite("History and Restore")
struct HistoryRestoreTests {
    final class Home: @unchecked Sendable {
        let path: String
        let env: ClaudeEnvironment
        static let settings = "{\n  \"theme\": \"dark\"\n}\n"
        var skill: String { joinPath(env.configDir, "skills/tidy") }

        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            path = url.resolvingSymlinksInPath().path
            env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [])
            try FileManager.default.createDirectory(atPath: skill, withIntermediateDirectories: true)
            try put(env.userSettingsFile, Self.settings)
            try put(joinPath(skill, "SKILL.md"), "---\nname: tidy\ndescription: Tidy\n---\nB\n")
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func put(_ file: String, _ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: file)) }
        func read(_ file: String) throws -> String {
            String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self)
        }
        var store: BackupStore { BackupStore(root: joinPath(path, ".claude.bak")) }
        var stash: HookStash { HookStash(root: joinPath(path, "stash")) }

        func pipeline(fault: @escaping @Sendable (ApplyStep) throws -> Void = { _ in }) -> ApplyPipeline {
            ApplyPipeline(
                environment: env, store: store, stash: stash, cli: nil, appVersion: "0.1.0", claudeVersion: nil,
                fault: fault)
        }

        /// Turns `tidy` off, then removes it: one settings edit and one folder moved to the backup.
        func applyTwo(fault: @escaping @Sendable (ApplyStep) throws -> Void = { _ in }) async throws -> ApplyResult {
            let items = await ConfigScanner(environment: env, fileSystem: LocalFileSystem(), cli: nil).scan().items
            let tidy = try #require(items.first { $0.concept == .skills && $0.name.hasSuffix("tidy") })
            let planner = Planner(environment: env, fileSystem: LocalFileSystem())
            let scope = WriteScope(scope: .user, file: env.userSettingsFile)
            let changes = try planner.plan(
                [.setEnabled(tidy, false), .remove(tidy, keepData: true)], writeScope: scope, activeProject: nil
            )
            .map { try $0.get() }
            return try await pipeline(fault: fault).apply(changes, title: "Apply 2 changes")
        }
    }

    struct Injected: Error {}

    @Test("History lists each Apply, newest first, with its files; only an applied one can be restored")
    func rows() async throws {
        let home = try Home()
        _ = try await home.applyTwo()
        try home.put(home.env.userSettingsFile, Home.settings)
        try FileManager.default.createDirectory(atPath: home.skill, withIntermediateDirectories: true)
        try home.put(joinPath(home.skill, "SKILL.md"), "---\nname: tidy\ndescription: Tidy\n---\nB\n")
        _ = try await home.applyTwo(fault: { if $0 == .filesWritten { throw Injected() } })
        let (rows, problems) = HistoryList.rows(store: home.store, home: home.path)
        #expect(problems.isEmpty)
        #expect(rows.count >= 2)
        #expect(rows.first?.result == .rolledBack, "newest first")
        #expect(rows.first?.canRestore == false)
        let applied = try #require(rows.first { $0.title == "Apply 2 changes" && $0.result == .applied })
        #expect(applied.canRestore)
        #expect(applied.date != nil, "the recorded time reads as a date")
        #expect(applied.files.contains("~/.claude/settings.json"))
        #expect(applied.files.contains("~/.claude/skills/tidy"))
        #expect(HistoryList.filter(rows, query: "apply", filter: .undone).allSatisfy { $0.result != .applied })
        #expect(HistoryList.filter(rows, query: "nothing like this", filter: .all).isEmpty)
    }

    @Test("Restore shows what it puts back, then returns the files to the backed-up bytes")
    func restore() async throws {
        let home = try Home()
        let applied = try await home.applyTwo()
        #expect(!FileManager.default.fileExists(atPath: home.skill))

        let preview = try RestorePreview.make(id: applied.backupId, store: home.store, stash: home.stash, home: home.path)
        #expect(preview.conflicts.isEmpty)
        #expect(preview.canRestore)
        #expect(preview.files.contains { $0.path == "~/.claude/settings.json" })
        #expect(preview.files.contains { $0.path.hasPrefix("~/.claude/skills/tidy") })

        let outcome = await RestorePreview.run(preview, pipeline: home.pipeline(), home: home.path)
        #expect(outcome.kind == .applied, "\(outcome.detail ?? "")")
        #expect(try home.read(home.env.userSettingsFile) == Home.settings)
        #expect(try home.read(joinPath(home.skill, "SKILL.md")).contains("name: tidy"))
        let (rows, _) = HistoryList.rows(store: home.store, home: home.path)
        #expect(rows.first?.title == "Restore \(applied.backupId)")
    }

    @Test("A file changed after the backup is a conflict; restore waits until it is accepted")
    func conflict() async throws {
        let home = try Home()
        let applied = try await home.applyTwo()
        try home.put(home.env.userSettingsFile, "{\"theirs\": true}\n")

        let held = try RestorePreview.make(id: applied.backupId, store: home.store, stash: home.stash, home: home.path)
        #expect(held.conflicts.map(\.path) == ["~/.claude/settings.json"])
        #expect(!held.canRestore)
        let refused = await RestorePreview.run(held, pipeline: home.pipeline(), home: home.path)
        #expect(refused.wroteNothing)
        #expect(try home.read(home.env.userSettingsFile) == "{\"theirs\": true}\n")

        let accepted = try RestorePreview.make(
            id: applied.backupId, accept: [home.env.userSettingsFile], store: home.store, stash: home.stash,
            home: home.path)
        #expect(accepted.canRestore)
        let outcome = await RestorePreview.run(accepted, pipeline: home.pipeline(), home: home.path)
        #expect(outcome.kind == .applied)
        #expect(try home.read(home.env.userSettingsFile) == Home.settings)
    }
}
