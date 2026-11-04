import Foundation
import Testing

@testable import ClawCore

@Suite("Projects, progress and cancel")
struct ProjectTests {
    @Test("Discovery reads ~/.claude.json project keys that still exist")
    func discovery() {
        let fs = MemoryFileSystem([
            "/h/.claude.json": #"{"projects":{"/work/a":{},"/work/gone":{},"relative":{},"/work/b":{"mcpServers":{}}}}"#,
            "/work/a/CLAUDE.md": "x",
            "/work/b/.claude/settings.json": "{}",
        ])
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed")
        #expect(ProjectDiscovery(fileSystem: fs).knownProjects(environment: env) == ["/work/a", "/work/b"])
    }

    @Test("Registry add, remove, de-duplicate and save atomically with owner-only permissions")
    func registry() throws {
        let fs = LocalFileSystem()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("claw-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = joinPath(dir, "real")
        let link = joinPath(dir, "link")
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

        var list = ProjectRegistry.adding(real, to: [], now: Date(timeIntervalSince1970: 0), fileSystem: fs)
        list = ProjectRegistry.adding(link, to: list, fileSystem: fs)
        #expect(list.map(\.path) == [real])

        let registry = ProjectRegistry(file: joinPath(dir, "store", "projects.json"))
        try registry.save(list)
        let attributes = try FileManager.default.attributesOfItem(atPath: registry.file)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let (loaded, problems) = registry.load(fileSystem: fs)
        #expect(loaded == list)
        #expect(problems.isEmpty)

        #expect(ProjectRegistry.removing(link, from: loaded, fileSystem: fs).isEmpty)
        #expect(ProjectRegistry.deduplicated([link, real], fileSystem: fs).count == 1)

        try Data("not json".utf8).write(to: URL(fileURLWithPath: registry.file))
        #expect(registry.load(fileSystem: fs).1.count == 1)
    }

    @Test("Progress reports every step in order")
    func progress() async {
        let steps = StepLog()
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed")
        _ = await Scanner(environment: env, fileSystem: MemoryFileSystem([:]), cli: nil).scan { steps.append($0.step) }
        #expect(steps.values == ScanProgress.Step.allCases.filter { $0 != .done } + [.done])
        #expect(ScanProgress.Step.done.fraction == 1)
    }

    @Test("Stop returns quickly with a partial result, even while claude is running")
    func cancel() async {
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed")
        let cli = ClaudeCLI(executable: "/bin/sleep", runner: SleepingRunner(), timeoutSeconds: 30)
        let scanner = Scanner(environment: env, fileSystem: MemoryFileSystem([:]), cli: cli)
        let started = Date()
        let task = Task { await scanner.scan() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let result = await task.value
        #expect(result.partial)
        #expect(result.problems.contains { $0.message.contains("stopped") })
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("Real process is stopped when the task is cancelled")
    func cancelProcess() async {
        let started = Date()
        let task = Task { try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["20"], timeoutSeconds: 30) }
        try? await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }
}

/// Runs a real `sleep` so cancellation goes through `ProcessRunner`.
struct SleepingRunner: CommandRunner {
    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
        try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["20"], timeoutSeconds: timeoutSeconds)
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [ScanProgress.Step] = []
    func append(_ step: ScanProgress.Step) { lock.withLock { steps.append(step) } }
    var values: [ScanProgress.Step] { lock.withLock { steps } }
}
