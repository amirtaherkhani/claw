import Foundation
import Testing

@testable import ClawCore

private final class Sandbox {
    let path: String
    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        path = url.resolvingSymlinksInPath().path
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }
    func file(_ name: String) -> String { joinPath(path, name) }
    var store: BackupStore { BackupStore(root: file("backups")) }

    func put(_ name: String, _ text: String, mode: Int = 0o644) throws {
        let target = file(name)
        try FileManager.default.createDirectory(
            atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: target))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target)
    }

    func read(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: file(name))), as: UTF8.self)
    }

    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name)) }
}

private func sha(_ text: String) -> String { SHA256.hex(Data(text.utf8)) }

@Suite("History")
struct HistoryTests {
    private func entry(_ id: String, _ title: String = "Disabled a plugin") -> HistoryEntry {
        HistoryEntry(
            id: id, time: "2026-11-05T07-54-05Z", title: title, files: ["/h/.claude/settings.json"], backupId: id,
            result: .applied)
    }

    @Test("Entries are appended one per line, oldest first, in a private file")
    func append() throws {
        let sandbox = try Sandbox()
        let log = sandbox.store.history
        try log.append(entry("a"))
        try log.append(entry("b", "line\nbreak"))
        let (entries, problems) = try log.entries()
        #expect(entries.map(\.id) == ["a", "b"])
        #expect(entries[1].title == "line\nbreak")
        #expect(problems.isEmpty)
        let text = try sandbox.read("backups/history.jsonl")
        #expect(text.split(separator: "\n").count == 2)
        #expect(text.hasSuffix("\n"))
        let mode = try FileManager.default.attributesOfItem(atPath: log.file)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("No file means no history")
    func empty() throws {
        let sandbox = try Sandbox()
        let (entries, problems) = try sandbox.store.history.entries()
        #expect(entries.isEmpty)
        #expect(problems.isEmpty)
    }

    @Test("A torn or damaged line is reported, and the rest still reads")
    func damaged() throws {
        let sandbox = try Sandbox()
        let log = sandbox.store.history
        try log.append(entry("a"))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: log.file))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"torn".utf8))
        try handle.close()
        try log.append(entry("b"))
        let (entries, problems) = try log.entries()
        #expect(entries.map(\.id) == ["a", "b"])
        #expect(problems.count == 1)
    }

    @Test("Appending keeps what is there, byte for byte")
    func appendOnly() throws {
        let sandbox = try Sandbox()
        let log = sandbox.store.history
        try log.append(entry("a"))
        let before = try Data(contentsOf: URL(fileURLWithPath: log.file))
        try log.append(entry("b"))
        let after = try Data(contentsOf: URL(fileURLWithPath: log.file))
        #expect(after.prefix(before.count) == before)
    }
}

/// An Apply stopped at each step: nothing after the step ran, as after a kill. It changes `a.json`, creates
/// `new.json` and removes `old.md`. Hashes go in the manifest before the write, as the pipeline must do.
enum Stop: CaseIterable, Sendable {
    case afterBackupStarted, afterOriginalsKept, afterHashesRecorded, afterFirstWrite, afterSecondWrite
    case afterMoveRecorded, afterMoved
}

@Suite("Recovery after an interrupted apply")
struct RecoveryTests {
    private func interruptedApply(_ sandbox: Sandbox, stop: Stop) throws -> String {
        try sandbox.put("a.json", "old", mode: 0o640)
        try sandbox.put("old.md", "kept", mode: 0o640)
        var session = try sandbox.store.start(appVersion: "1", claudeVersion: nil, operations: [])
        let id = session.manifest.id
        if stop == .afterBackupStarted { return id }
        try session.keepOriginal(of: sandbox.file("a.json"))
        try session.keepOriginal(of: sandbox.file("new.json"))
        if stop == .afterOriginalsKept { return id }
        try session.recordResult(of: sandbox.file("a.json"), sha256After: sha("new"))
        try session.recordResult(of: sandbox.file("new.json"), sha256After: sha("created"))
        if stop == .afterHashesRecorded { return id }
        try AtomicWrite.write(Data("new".utf8), to: sandbox.file("a.json"), expectedSHA256: sha("old"))
        if stop == .afterFirstWrite { return id }
        try AtomicWrite.write(Data("created".utf8), to: sandbox.file("new.json"), expectedSHA256: nil)
        if stop == .afterSecondWrite { return id }
        if stop == .afterMoveRecorded {
            try session.recordMove(of: sandbox.file("old.md"))
            return id
        }
        try session.moveAway(sandbox.file("old.md"))
        return id
    }

    @Test("Rolling back from any step gives the old files back", arguments: Stop.allCases)
    func everyStep(stop: Stop) throws {
        let sandbox = try Sandbox()
        let id = try interruptedApply(sandbox, stop: stop)
        #expect(try sandbox.store.interrupted() == [id])

        let result = try sandbox.store.rollBack(id: id)
        #expect(result.kept.isEmpty)
        #expect(try sandbox.read("a.json") == "old")
        #expect(try sandbox.read("old.md") == "kept")
        #expect(!sandbox.exists("new.json"))
        let mode = try FileManager.default.attributesOfItem(atPath: sandbox.file("old.md"))[.posixPermissions] as? Int
        #expect(mode == 0o640)
        #expect(try sandbox.store.manifest(id: id).status == .rolledBack)
        #expect(try sandbox.store.interrupted().isEmpty)
        #expect(try sandbox.store.history.entries().entries.last?.result == .rolledBack)
    }

    @Test("A file created by the apply is moved aside, never deleted")
    func createdFileIsKept() throws {
        let sandbox = try Sandbox()
        let id = try interruptedApply(sandbox, stop: .afterSecondWrite)
        _ = try sandbox.store.rollBack(id: id)
        #expect(try sandbox.read("backups/\(id)/removed" + sandbox.file("new.json")) == "created")
    }

    @Test("Inspecting reports each file and changes nothing")
    func inspect() throws {
        let sandbox = try Sandbox()
        let id = try interruptedApply(sandbox, stop: .afterFirstWrite)
        let report = try sandbox.store.inspect(id: id)
        #expect(report.files[sandbox.file("a.json")] == .written)
        #expect(report.files[sandbox.file("new.json")] == .untouched)
        #expect(try sandbox.read("a.json") == "new")
        #expect(try sandbox.store.manifest(id: id).status == .inProgress)
    }

    @Test("A file someone else changed is left alone and reported")
    func changedElsewhere() throws {
        let sandbox = try Sandbox()
        let id = try interruptedApply(sandbox, stop: .afterSecondWrite)
        try sandbox.put("a.json", "claude wrote this")
        #expect(try sandbox.store.inspect(id: id).files[sandbox.file("a.json")] == .changedElsewhere)

        let result = try sandbox.store.rollBack(id: id)
        #expect(result.kept == [sandbox.file("a.json")])
        #expect(try sandbox.read("a.json") == "claude wrote this")
        #expect(!sandbox.exists("new.json"))
        #expect(try sandbox.store.manifest(id: id).status == .failed)
        #expect(try sandbox.store.interrupted().isEmpty)
    }

    @Test("Something back in a removed item's place is not overwritten")
    func moveTargetTaken() throws {
        let sandbox = try Sandbox()
        let id = try interruptedApply(sandbox, stop: .afterMoved)
        try sandbox.put("old.md", "a new file")
        let result = try sandbox.store.rollBack(id: id)
        #expect(result.kept == [sandbox.file("old.md")])
        #expect(try sandbox.read("old.md") == "a new file")
        #expect(try sandbox.read("backups/\(id)/removed" + sandbox.file("old.md")) == "kept")
    }

    @Test("Running the rollback again after it was cut short is safe")
    func secondRun() throws {
        let sandbox = try Sandbox()
        let id = try interruptedApply(sandbox, stop: .afterMoved)
        let first = try sandbox.store.rollBack(id: id)
        #expect(first.kept.isEmpty)
        var manifest = try sandbox.store.manifest(id: id)
        manifest.status = .inProgress
        let encoder = JSONEncoder()
        try encoder.encode(manifest).write(to: URL(fileURLWithPath: sandbox.file("backups/\(id)/manifest.json")))
        let second = try sandbox.store.rollBack(id: id)
        #expect(second.kept.isEmpty)
        #expect(try sandbox.read("a.json") == "old")
        #expect(try sandbox.read("old.md") == "kept")
        #expect(!sandbox.exists("new.json"))
        #expect(try sandbox.store.manifest(id: id).moves.count == 2, "the created file was not put back and moved again")
    }

    @Test("Finished backups are not interrupted, and cannot be rolled back this way")
    func finished() throws {
        let sandbox = try Sandbox()
        var session = try sandbox.store.start(appVersion: "1", claudeVersion: nil, operations: [])
        try session.finish(.applied)
        #expect(try sandbox.store.interrupted().isEmpty)
        #expect(throws: BackupError.self) { try sandbox.store.rollBack(id: session.manifest.id) }
    }

    @Test("Moving the same path twice in one backup never replaces the first copy")
    func moveTwice() throws {
        let sandbox = try Sandbox()
        var session = try sandbox.store.start(appVersion: "1", claudeVersion: nil, operations: [])
        try sandbox.put("x.md", "first")
        try session.moveAway(sandbox.file("x.md"))
        try sandbox.put("x.md", "second")
        #expect(throws: BackupError.self) { try session.moveAway(sandbox.file("x.md")) }
        #expect(try sandbox.read("x.md") == "second")
        #expect(try sandbox.read("backups/\(session.manifest.id)/removed" + sandbox.file("x.md")) == "first")
    }
}
