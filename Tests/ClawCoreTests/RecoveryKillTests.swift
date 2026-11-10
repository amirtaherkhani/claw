import Foundation
import Testing

@testable import ClawCore

/// M2.16 and M2.4: the real `claw` binary is killed with SIGKILL at each step of a change, in a temporary HOME.
/// The next start must report the step it reached, and Cancel, Continue or OK must leave every file fully old
/// or fully new. Nothing here touches the real `~/.claude`: the child gets an exact environment.
enum ClawBinary {
    static let path: String? = {
        var folder = URL(fileURLWithPath: #filePath)
        while folder.path != "/" {
            folder.deleteLastPathComponent()
            let candidate = folder.appendingPathComponent(".build/debug/claw").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }()
}

private final class Home: @unchecked Sendable {
    let path: String
    let env: ClaudeEnvironment
    static let original = Data(
        #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/echo done"}]}]}}"#.utf8)

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claw-kill-\(UUID().uuidString)")
        path = url.resolvingSymlinksInPath().path
        env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [])
        try FileManager.default.createDirectory(atPath: env.configDir, withIntermediateDirectories: true)
        try Self.original.write(to: URL(fileURLWithPath: env.userSettingsFile))
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    var settings: Data { FileManager.default.contents(atPath: env.userSettingsFile) ?? Data() }
    var store: BackupStore { get throws { try BackupStore(environment: env) } }
    var liveStash: [HookStashEntry] { (try? HookStash(environment: env).entries()) ?? [] }

    /// Runs `claw apply disable` on the hook and returns how the process ended.
    func killed(at point: CrashPoint) throws -> (Process.TerminationReason, Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(ClawBinary.path))
        process.arguments = ["apply", "disable", "Stop · echo"]
        process.environment = ["HOME": path, "PATH": "/usr/bin:/bin", "CLAW_TEST_KILL_AT": point.rawValue]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (process.terminationReason, process.terminationStatus)
    }

    func commands() throws -> WriteCommands {
        let env = self.env
        return WriteCommands(
            environment: env, fileSystem: LocalFileSystem(), store: try store, stash: HookStash(environment: env),
            cli: nil, appVersion: "0.1.0", claudeVersion: nil, scan: { await ConfigScanner(environment: env, cli: nil).scan() })
    }

    func interrupted() throws -> [InterruptedChange] { try store.interruptedChanges() }

    var hookIsOff: Bool {
        get throws {
            let value = try JSONValue.parse(settings)
            return value["hooks"]?["Stop"] == nil && value["theme"]?.stringValue == "dark"
        }
    }
}

@Suite("Recovery after a real kill", .serialized, .enabled(if: ClawBinary.path != nil, "build the claw binary first"))
struct RecoveryKillTests {
    static let unfinished: [CrashPoint] = [.backup, .write, .verify]
    static let expectedStep: [CrashPoint: InterruptedStep] = [
        .backup: .backup, .write: .write, .verify: .verify, .finish: .finish,
    ]

    @Test("A kill at each step is reported by the step it reached", arguments: CrashPoint.allCases)
    func reported(point: CrashPoint) throws {
        let home = try Home()
        let (reason, status) = try home.killed(at: point)
        #expect(reason == .uncaughtSignal && status == SIGKILL, "claw was not killed: \(reason) \(status)")
        let found = try home.interrupted()
        #expect(found.map(\.step) == [Self.expectedStep[point]])
        let change = try #require(found.first)
        #expect(change.canContinue == (point != .finish))
        #expect(change.canCancel == (point != .finish))
    }

    @Test("Cancel puts every file back as it was", arguments: unfinished)
    func cancel(point: CrashPoint) async throws {
        let home = try Home()
        _ = try home.killed(at: point)
        let id = try #require(try home.interrupted().first?.id)
        let result = await (try home.commands()).recover(id: id, choice: .cancel)
        #expect(result.exitCode == 0, "\(result.output)")
        #expect(home.settings == Home.original)
        #expect(home.liveStash.isEmpty)
        #expect(try home.interrupted().isEmpty)
    }

    @Test("Continue finishes the change, and the hook is listed as turned off by Claw", arguments: unfinished)
    func resume(point: CrashPoint) async throws {
        let home = try Home()
        _ = try home.killed(at: point)
        let id = try #require(try home.interrupted().first?.id)
        let result = await (try home.commands()).recover(id: id, choice: .continue)
        #expect(result.exitCode == 0, "\(result.output)")
        #expect(try home.hookIsOff)
        #expect(home.liveStash.count == 1)
        #expect(try home.interrupted().isEmpty)
        let hooks = await ConfigScanner(environment: home.env, cli: nil).scan().items.filter { $0.concept == .hooks }
        #expect(hooks.map(ItemPresentation.stateText) == ["Off (turned off by Claw)"])
    }

    @Test("A kill after the change was done: OK records it in History, nothing else changes")
    func done() async throws {
        let home = try Home()
        _ = try home.killed(at: .finish)
        let id = try #require(try home.interrupted().first?.id)
        let refused = await (try home.commands()).recover(id: id, choice: .cancel)
        #expect(refused.exitCode == 2)
        let result = await (try home.commands()).recover(id: id, choice: .ok)
        #expect(result.exitCode == 0, "\(result.output)")
        #expect(try home.hookIsOff)
        #expect(try home.store.history.entries().entries.map(\.backupId) == [id])
        #expect(try home.interrupted().isEmpty)
    }

    @Test("A file changed by someone else after the kill: only Cancel, and it leaves that file alone")
    func changedElsewhere() async throws {
        let home = try Home()
        _ = try home.killed(at: .verify)
        let theirs = Data(#"{"theme":"light"}"#.utf8)
        try theirs.write(to: URL(fileURLWithPath: home.env.userSettingsFile))
        let change = try #require(try home.interrupted().first)
        #expect(change.changedElsewhere == [home.env.userSettingsFile])
        #expect(!change.canContinue)
        let refused = await (try home.commands()).recover(id: change.id, choice: .continue)
        #expect(refused.exitCode == 2)
        #expect(home.settings == theirs)
        let cancelled = await (try home.commands()).recover(id: change.id, choice: .cancel)
        #expect(cancelled.output.contains("Left alone"))
        #expect(home.settings == theirs)
    }
}
