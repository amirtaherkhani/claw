import Foundation
import Testing

@testable import ClawCore

/// F9: macOS holds `open()` on a protected folder until its privacy dialog is answered.
@Suite("Scan during a blocked read")
struct BlockedReadTests {
    static let blocked = "/h/.claude/settings.json"
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed")

    @Test("Stop returns within a second while a read is blocked")
    func stopDuringBlockedRead() async throws {
        let gate = ReadGate()
        defer { gate.release() }
        let fs = BlockingFileSystem(blocked: Self.blocked, gate: gate)
        let scanner = ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil)

        let task = Task { await scanner.scan() }
        try await gate.waitUntilHolding()
        task.cancel()
        let result = await value(of: task, within: 1)

        #expect(result?.partial == true)
        #expect(result?.problems.contains { $0.message.contains("stopped") } == true)
    }

    @Test("Stop keeps the finished steps, and the blocked step adds nothing")
    func stopKeepsFinishedSteps() async throws {
        let skill = "/h/.claude/skills/a/SKILL.md"
        let gate = ReadGate()
        defer { gate.release() }
        let fs = BlockingFileSystem(
            files: [Self.blocked: #"{"enabledPlugins":{"p@m":true}}"#, skill: "---\nname: a\n---\n"],
            blocked: skill, gate: gate)
        let scanner = ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil)

        let task = Task { await scanner.scan() }
        try await gate.waitUntilHolding()
        task.cancel()
        let result = await value(of: task, within: 1)

        #expect(result?.items.map(\.concept) == [.plugins])
    }

    @Test("After Stop, the abandoned thread touches the disk no more")
    func abandonedThreadStopsReading() async throws {
        let gate = ReadGate()
        defer { gate.release() }
        let fs = BlockingFileSystem(blocked: Self.env.managedSettingsFile, gate: gate)
        let scanner = ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil)

        let task = Task { await scanner.scan() }
        try await gate.waitUntilHolding()
        task.cancel()
        _ = await value(of: task, within: 1)
        gate.release()
        try await Task.sleep(for: .milliseconds(100))

        #expect(fs.log.reads == [Self.env.managedSettingsFile])
    }

    @Test("Reads run on a dedicated thread, not the Swift concurrency pool")
    func readsLeaveThePool() async {
        let fs = BlockingFileSystem(blocked: "", gate: ReadGate())
        _ = await ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil).scan()
        #expect(!fs.log.threads.isEmpty)
        #expect(fs.log.threads == [StoppableFileSystem.threadName])
    }

    @Test("Progress names a stalled read and clears it when the read returns")
    func stallIsReported() async throws {
        let gate = ReadGate()
        defer { gate.release() }
        let log = ProgressLog()
        let fs = BlockingFileSystem(blocked: Self.blocked, gate: gate)
        let scanner = ConfigScanner(
            environment: Self.env, fileSystem: fs, cli: nil, stallThreshold: .milliseconds(50))

        let task = Task { await scanner.scan { log.append($0) } }
        let deadline = ContinuousClock.now + .seconds(5)
        while log.values.allSatisfy({ $0.waitingOn == nil }) {
            try #require(ContinuousClock.now < deadline, "no stall was reported")
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(log.values.last == ScanProgress(step: .settings, itemCount: 0, waitingOn: Self.blocked))

        gate.release()
        _ = await value(of: task, within: 5)
        #expect(log.values.last?.step == .done)
        #expect(log.values.last?.waitingOn == nil)
    }

    @Test("A scan with no slow read reports no stall, whatever the step takes")
    func noFalseStall() async {
        let log = ProgressLog()
        let cli = ClaudeCLI(executable: "/bin/sleep", runner: DelayedRunner(), timeoutSeconds: 5)
        let scanner = ConfigScanner(
            environment: Self.env, fileSystem: MemoryFileSystem([:]), cli: cli, stallThreshold: .milliseconds(50))
        _ = await scanner.scan { log.append($0) }
        #expect(log.values.allSatisfy { $0.waitingOn == nil })
    }

    @Test("Stop returns while reading modification dates is blocked")
    func stopDuringDates() async throws {
        let skill = "/h/.claude/skills/a/SKILL.md"
        let memory = MemoryFileSystem([skill: "---\nname: a\n---\n"])
        let items = await ConfigScanner(environment: Self.env, fileSystem: memory, cli: nil).scan().items
        let gate = ReadGate()
        defer { gate.release() }
        let file = try #require(items.first.map(ItemPresentation.file))
        let fs = BlockingFileSystem(blocked: file, gate: gate)
        let scanner = ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil)

        let task = Task { await scanner.modificationDates(for: items) }
        try await gate.waitUntilHolding()
        task.cancel()

        #expect(await value(of: task, within: 1) == [:])
    }

    @Test("Dates after Stop return at once and touch no disk")
    func datesAfterStop() async throws {
        let skill = "/h/.claude/skills/a/SKILL.md"
        let memory = MemoryFileSystem([skill: "---\nname: a\n---\n"])
        let items = await ConfigScanner(environment: Self.env, fileSystem: memory, cli: nil).scan().items
        let gate = ReadGate()
        defer { gate.release() }
        let file = try #require(items.first.map(ItemPresentation.file))
        let fs = BlockingFileSystem(blocked: file, gate: gate)
        let scanner = ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil)

        // The app asks for dates in the task Stop cancelled, so the task is already cancelled here.
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await scanner.modificationDates(for: items)
        }

        #expect(await value(of: task, within: 1) == [:])
        try await Task.sleep(for: .milliseconds(100))
        #expect(fs.log.reads.isEmpty)
    }
}

/// Waits for the task, giving up after `seconds`. A blocked scan may never finish, so a plain
/// `await task.value` would hang the test run instead of failing it.
func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
    let box = Latest<T>()
    Task { box.set(await task.value) }
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if let value = box.value { return value }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return box.value
}

final class Latest<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    func set(_ value: T) { lock.withLock { stored = value } }
    var value: T? { lock.withLock { stored } }
}

/// Holds a caller until released.
final class ReadGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var holding = false
    private var released = false

    func hold() {
        condition.lock()
        holding = true
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    private var isHolding: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holding
    }

    func waitUntilHolding() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !isHolding {
            try #require(ContinuousClock.now < deadline, "the scan never reached the blocked read")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Records what reached the disk.
final class DiskLog: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var names: Set<String> = []

    func record(_ path: String) {
        let name = Thread.current.name ?? ""
        lock.withLock {
            paths.append(path)
            names.insert(name)
        }
    }

    var reads: [String] { lock.withLock { paths } }
    var threads: Set<String> { lock.withLock { names } }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [ScanProgress] = []
    func append(_ update: ScanProgress) { lock.withLock { updates.append(update) } }
    var values: [ScanProgress] { lock.withLock { updates } }
}

/// `MemoryFileSystem` whose reads of one path hold at the gate, the way macOS holds `open()`.
struct BlockingFileSystem: ReadonlyFileSystem {
    let memory: MemoryFileSystem
    let blocked: String
    let gate: ReadGate
    let log = DiskLog()

    init(files: [String: String] = [:], blocked: String, gate: ReadGate) {
        memory = MemoryFileSystem(files)
        self.blocked = blocked
        self.gate = gate
    }

    func readFile(_ path: String) throws -> Data? {
        log.record(path)
        if path == blocked { gate.hold() }
        return try memory.readFile(path)
    }

    func modificationDate(_ path: String) -> Date? {
        log.record(path)
        if path == blocked { gate.hold() }
        return nil
    }

    func contentsOfDirectory(_ path: String) throws -> [String]? { try memory.contentsOfDirectory(path) }
    func isDirectory(_ path: String) -> Bool { memory.isDirectory(path) }
    func fileExists(_ path: String) -> Bool { memory.fileExists(path) }
    func resolvingSymlinks(_ path: String) -> String { path }
}

/// A `claude` that takes longer than the stall threshold: slow, but no disk call is stuck.
struct DelayedRunner: CommandRunner {
    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
        try await Task.sleep(for: .milliseconds(400))
        return ok(arguments == ["--version"] ? "2.1.0 (Claude Code)" : "[]")
    }
}
