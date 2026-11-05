import Foundation
import Testing

@testable import ClawCore

@Suite("Backup store")
struct BackupStoreTests {
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
    }

    private let date = Date(timeIntervalSince1970: 1_793_865_245)

    private func start(_ sandbox: Sandbox) throws -> BackupSession {
        try sandbox.store.start(
            date: date, appVersion: "0.1.0", claudeVersion: "2.1.316", operations: [.object(["op": .string("setEnabled")])])
    }

    private func put(_ path: String, _ text: String, mode: Int = 0o644) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func mode(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    private func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    @Test("A backup folder is private, named by time, and starts in progress")
    func start() throws {
        let sandbox = try Sandbox()
        let session = try start(sandbox)
        #expect(session.manifest.id == "2026-11-05T07-54-05Z")
        #expect(session.folder == joinPath(sandbox.file("backups"), "2026-11-05T07-54-05Z"))
        #expect(try mode(sandbox.file("backups")) == 0o700)
        #expect(try mode(session.folder) == 0o700)
        #expect(try mode(joinPath(session.folder, "manifest.json")) == 0o600)
        #expect(try sandbox.store.manifest(id: session.manifest.id) == session.manifest)
        #expect(session.manifest.status == .inProgress)
    }

    @Test("A folder that was too open is made private")
    func tightensRoot() throws {
        let sandbox = try Sandbox()
        try FileManager.default.createDirectory(atPath: sandbox.file("backups"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.file("backups"))
        _ = try start(sandbox)
        #expect(try mode(sandbox.file("backups")) == 0o700)
    }

    @Test("Two backups in the same second get different folders")
    func sameSecond() throws {
        let sandbox = try Sandbox()
        let first = try start(sandbox)
        let second = try start(sandbox)
        #expect(first.folder != second.folder)
        #expect(second.manifest.id == "2026-11-05T07-54-05Z-2")
    }

    @Test("The manifest has the shape in TECHNICAL-DESIGN 9.4")
    func manifestShape() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        let target = sandbox.file("home/.claude/settings.json")
        try put(target, "{}")
        try session.keepOriginal(of: target)
        try session.recordResult(of: target, sha256After: "after")
        let json = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: joinPath(session.folder, "manifest.json"))))
        #expect(json["schema"] == .number(1))
        #expect(json["status"] == .string("in-progress"))
        #expect(json["app"]?["version"] == .string("0.1.0"))
        #expect(json["claudeCode"]?["version"] == .string("2.1.316"))
        #expect(json["operations"]?.arrayValue?.count == 1)
        let file = try #require(json["files"]?.arrayValue?.first)
        #expect(file["path"] == .string(target))
        #expect(file["existed"] == .bool(true))
        #expect(file["sha256Before"] == .string(SHA256.hex(Data("{}".utf8))))
        #expect(file["sha256After"] == .string("after"))
        #expect(file["mode"] == .number(0o644))
        for key in ["moves", "cli", "stash"] { #expect(json[key]?.arrayValue == []) }
    }

    @Test(
        "Each status is written as the design names it",
        arguments: [
            (BackupManifest.Status.inProgress, "in-progress"), (.applied, "applied"), (.rolledBack, "rolled-back"),
            (.failed, "failed"),
        ])
    func statuses(status: BackupManifest.Status, name: String) throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        try session.finish(status)
        let json = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: joinPath(session.folder, "manifest.json"))))
        #expect(json["status"] == .string(name))
        #expect(try sandbox.store.manifest(id: session.manifest.id).status == status)
    }

    @Test("An original is copied under files/, private, and the source stays")
    func keepsOriginal() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        let target = sandbox.file("home/.claude/settings.json")
        try put(target, "original")
        try session.keepOriginal(of: target)
        let copy = session.folder + "/files" + target
        #expect(try read(copy) == "original")
        #expect(try mode(copy) == 0o600)
        #expect(try mode((copy as NSString).deletingLastPathComponent) == 0o700)
        #expect(try read(target) == "original")
        #expect(try mode(target) == 0o644)
        #expect(try session.original(of: target) == Data("original".utf8))
    }

    @Test("Keeping the same file twice records it once, with the first bytes")
    func keepsOnce() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        let target = sandbox.file("a.json")
        try put(target, "first")
        try session.keepOriginal(of: target)
        try put(target, "second")
        try session.keepOriginal(of: target)
        #expect(session.manifest.files.count == 1)
        #expect(try session.original(of: target) == Data("first".utf8))
    }

    @Test("A file that does not exist yet is recorded as such")
    func missingOriginal() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        let target = sandbox.file("new.json")
        try session.keepOriginal(of: target)
        #expect(session.manifest.files.first?.existed == false)
        #expect(session.manifest.files.first?.sha256Before == nil)
        #expect(try session.original(of: target) == nil)
    }

    @Test("A symlinked file is kept by its bytes, and the link stays")
    func symlinkedOriginal() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        let real = sandbox.file("real.json")
        let link = sandbox.file("link.json")
        try put(real, "through the link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        try session.keepOriginal(of: link)
        #expect(try session.original(of: link) == Data("through the link".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == real)
    }

    @Test("Removing moves a file: same bytes in removed/, private, gone from its place")
    func movesFile() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        let target = sandbox.file("home/.claude/commands/old.md")
        try put(target, "body", mode: 0o640)
        try session.moveAway(target)
        let moved = session.folder + "/removed" + target
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(try read(moved) == "body")
        #expect(try mode(moved) == 0o600)
        let record = try #require(session.manifest.moves.first)
        #expect(record.from == target)
        #expect(record.to == "removed" + target)
        #expect(record.modes[""] == 0o640)
    }

    @Test("Removing a folder moves it whole and remembers each mode")
    func movesFolder() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        let target = sandbox.file("home/.claude/skills/old")
        try put(joinPath(target, "SKILL.md"), "skill", mode: 0o644)
        try put(joinPath(target, "scripts/run.sh"), "#!/bin/sh", mode: 0o755)
        try session.moveAway(target)
        let moved = session.folder + "/removed" + target
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(try read(joinPath(moved, "scripts/run.sh")) == "#!/bin/sh")
        #expect(try mode(moved) == 0o700)
        #expect(try mode(joinPath(moved, "scripts")) == 0o700)
        #expect(try mode(joinPath(moved, "scripts/run.sh")) == 0o600)
        let record = try #require(session.manifest.moves.first)
        #expect(record.modes["scripts/run.sh"] == 0o755)
        #expect(record.modes["SKILL.md"] == 0o644)
    }

    @Test("Moving something that is not there fails")
    func moveMissing() throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        #expect(throws: BackupError.self) { try session.moveAway(sandbox.file("gone")) }
        #expect(session.manifest.moves.isEmpty)
    }

    @Test("Relative paths and paths with .. are refused", arguments: ["a.json", "/h/../etc/passwd", "/h/./a"])
    func unsafePaths(path: String) throws {
        let sandbox = try Sandbox()
        var session = try start(sandbox)
        #expect(throws: BackupError.self) { try session.keepOriginal(of: path) }
        #expect(throws: BackupError.self) { try session.moveAway(path) }
    }

    @Test("Claude Code's own backups folder is refused (FR-F12-6)")
    func refusesClaudeBackups() throws {
        let env = ClaudeEnvironment(home: "/h")
        #expect(throws: BackupError.self) { try BackupStore(root: "/h/.claude/backups", environment: env) }
        #expect(throws: BackupError.self) { try BackupStore(root: "/h/.claude/backups/claw", environment: env) }
        #expect(try BackupStore(environment: env).root == "/h/.claude.bak")
    }

    @Test("A backup that does not exist or is broken gives an error")
    func unreadable() throws {
        let sandbox = try Sandbox()
        #expect(throws: BackupError.self) { try sandbox.store.manifest(id: "nope") }
        #expect(throws: BackupError.self) { try sandbox.store.manifest(id: "../x") }
        let session = try start(sandbox)
        try Data("{".utf8).write(to: URL(fileURLWithPath: joinPath(session.folder, "manifest.json")))
        #expect(throws: BackupError.self) { try sandbox.store.manifest(id: session.manifest.id) }
    }

    @Test("Backups are listed oldest first")
    func listing() throws {
        let sandbox = try Sandbox()
        let first = try start(sandbox)
        let later = try sandbox.store.start(
            date: date.addingTimeInterval(60), appVersion: "1", claudeVersion: nil, operations: [])
        #expect(try sandbox.store.ids() == [first.manifest.id, later.manifest.id])
    }
}
