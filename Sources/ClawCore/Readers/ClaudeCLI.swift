import Foundation

public struct CommandResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable, CustomStringConvertible {
    case notFound
    case timedOut(seconds: Int)
    case invalidName(String)
    case failed(exitCode: Int32)
    case badOutput(String)

    public var description: String {
        switch self {
        case .notFound: "claude CLI not found"
        case .timedOut(let seconds): "claude CLI timed out after \(seconds) s"
        case .invalidName(let name): "invalid name: \(name)"
        case .failed(let code): "claude CLI exited with code \(code)"
        case .badOutput(let why): "unexpected claude CLI output: \(why)"
        }
    }
}

/// Runs a program without a shell. Tests use a fake.
public protocol CommandRunner: Sendable {
    func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult
}

/// `Foundation.Process` runner: argument vector only (no shell), stdin closed, hard timeout.
public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(executable: String, arguments: [String], timeoutSeconds: Int) async throws -> CommandResult {
        let box = ProcessBox(executable: executable, arguments: arguments)
        try await box.start()
        // Race the exit against the deadline and against cancellation (Stop). On Linux, `waitUntilExit` also
        // waits for the pipes, which a grandchild may keep open, so neither path depends on it. Bound: + 3 s.
        let once = ResumeOnce<Int32?>()
        let code: Int32? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.set(continuation)
                Task { once.resume(await box.waitForExit()) }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                    guard !once.isDone else { return }
                    box.terminateForTimeout()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    once.resume(nil)
                }
            }
        } onCancel: {
            box.terminateForTimeout()
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                once.resume(nil)
            }
        }
        if Task.isCancelled { throw CancellationError() }
        if box.didTimeOut || code == nil { throw CommandError.timedOut(seconds: timeoutSeconds) }
        let (stdout, stderr) = await box.collectOutput()
        return CommandResult(exitCode: code ?? -1, stdout: stdout, stderr: stderr)
    }
}

/// Resumes a continuation exactly once; later calls are ignored. A value that arrives before the
/// continuation is set is kept and delivered on `set`.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var pending: T?
    private var done = false

    var isDone: Bool { lock.withLock { done } }

    func set(_ continuation: CheckedContinuation<T, Never>) {
        let value: T? = lock.withLock {
            if let pending {
                self.pending = nil
                return pending
            }
            self.continuation = continuation
            return nil
        }
        if let value { continuation.resume(returning: value) }
    }

    func resume(_ value: T) {
        let target: CheckedContinuation<T, Never>? = lock.withLock {
            guard !done else { return nil }
            done = true
            if let continuation {
                self.continuation = nil
                return continuation
            }
            pending = value
            return nil
        }
        target?.resume(returning: value)
    }
}

/// Holds the non-Sendable Process and pipes. Shared state is guarded by `lock`.
private final class ProcessBox: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let lock = NSLock()
    private let readers = DispatchGroup()
    private var timedOut = false
    private var stdout = Data()
    private var stderr = Data()

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
    }

    /// Spawns from a fresh thread with an empty signal mask. Threads of the Swift concurrency pool and
    /// libdispatch block signals, and the child inherits that mask, so SIGTERM never arrived
    /// (seen on Linux with swift-corelibs-foundation).
    func start() async throws {
        try await onDedicatedThread { [self] in
            var empty = sigset_t()
            sigemptyset(&empty)
            pthread_sigmask(SIG_SETMASK, &empty, nil)
            try process.run()
        }
        startReader(outPipe.fileHandleForReading, isStdout: true)
        startReader(errPipe.fileHandleForReading, isStdout: false)
    }

    private func startReader(_ handle: FileHandle, isStdout: Bool) {
        readers.enter()
        let boxed = HandleBox(handle: handle)
        Thread.detachNewThread { [self] in
            let data = boxed.handle.readDataToEndOfFile()
            lock.withLock {
                if isStdout { stdout = data } else { stderr = data }
            }
            readers.leave()
        }
    }

    var didTimeOut: Bool { lock.withLock { timedOut } }

    /// SIGTERM, then SIGKILL after a 2 s grace period if the program ignores it.
    func terminateForTimeout() {
        let pid: Int32? = lock.withLock {
            guard process.isRunning else { return nil }
            timedOut = true
            process.terminate()
            return process.processIdentifier
        }
        guard let pid else { return }
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: 2)
            if lock.withLock({ process.isRunning }) { kill(pid, SIGKILL) }
        }
    }

    func waitForExit() async -> Int32 {
        (try? await onDedicatedThread { [self] in
            process.waitUntilExit()
            return process.terminationStatus
        }) ?? -1
    }

    func collectOutput() async -> (Data, Data) {
        (try? await onDedicatedThread { [self] in
            readers.wait()
            return lock.withLock { (stdout, stderr) }
        }) ?? (Data(), Data())
    }
}

private struct HandleBox: @unchecked Sendable {
    let handle: FileHandle
}

/// Runs blocking work on its own thread. Blocking `DispatchQueue.global()` workers instead can starve
/// the Swift concurrency pool on small machines (seen on a 2-core Linux runner: the timeout never fired).
private func onDedicatedThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread { continuation.resume(with: Result { try work() }) }
    }
}

/// Adapter for the `claude` CLI (TECHNICAL-DESIGN section 4).
public struct ClaudeCLI: Sendable {
    public let executable: String
    private let runner: any CommandRunner
    private let timeoutSeconds: Int

    public init(executable: String, runner: any CommandRunner = ProcessRunner(), timeoutSeconds: Int = 30) {
        self.executable = executable
        self.runner = runner
        self.timeoutSeconds = timeoutSeconds
    }

    /// Finds `claude` on `PATH` and in common install locations. GUI apps get a minimal `PATH`,
    /// so the fixed locations matter on macOS.
    public static func locate(environment: [String: String], home: String, fileSystem fs: any ReadonlyFileSystem) -> String? {
        let pathDirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let fixed = [
            joinPath(home, ".local", "bin"),
            joinPath(home, ".claude", "local"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for dir in pathDirs + fixed where !dir.isEmpty {
            let candidate = joinPath(dir, "claude")
            if fs.fileExists(candidate) && !fs.isDirectory(candidate) { return candidate }
        }
        return nil
    }

    /// First line of `claude --version`, for example `2.1.300 (Claude Code)`.
    public func version() async throws -> String {
        let result = try await runner.run(executable: executable, arguments: ["--version"], timeoutSeconds: timeoutSeconds)
        guard result.exitCode == 0 else { throw CommandError.failed(exitCode: result.exitCode) }
        let text = String(decoding: result.stdout, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
            !line.isEmpty
        else {
            throw CommandError.badOutput("empty version")
        }
        return line
    }

    /// `claude plugin list --json` [V `plugins/cli-reference`].
    public func pluginList() async throws -> PluginListParser.Result {
        let result = try await runner.run(
            executable: executable, arguments: ["plugin", "list", "--json"],
            timeoutSeconds: timeoutSeconds)
        guard result.exitCode == 0 else { throw CommandError.failed(exitCode: result.exitCode) }
        return try PluginListParser.parse(result.stdout)
    }
}

public enum PluginListParser {
    public struct Result: Sendable {
        public let plugins: [PluginRecord]
        public let problems: [Problem]
    }

    /// Accepts the whole output as JSON, or the last non-empty line (the CLI may print notices first).
    /// Entries without `id` or `installPath` are skipped with a problem; extra keys are ignored.
    public static func parse(_ data: Data) throws -> Result {
        let value: JSONValue
        if let whole = try? JSONValue.parse(data) {
            value = whole
        } else {
            let text = String(decoding: data, as: UTF8.self)
            guard
                let last = text.split(whereSeparator: \.isNewline).last(where: {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }),
                let parsed = try? JSONValue.parse(Data(last.utf8))
            else {
                throw CommandError.badOutput("not JSON")
            }
            value = parsed
        }
        guard let entries = value.arrayValue else { throw CommandError.badOutput("expected a JSON array") }

        var plugins: [PluginRecord] = []
        var problems: [Problem] = []
        for (index, entry) in entries.enumerated() {
            guard let id = entry["id"]?.stringValue, let installPath = entry["installPath"]?.stringValue else {
                problems.append(Problem(.warning, "plugin list entry \(index) has no id or installPath; skipped"))
                continue
            }
            guard NameValidator.isValidPluginId(id) else {
                problems.append(Problem(.warning, "plugin list entry \(index) has an unsafe id; skipped"))
                continue
            }
            plugins.append(
                PluginRecord(
                    id: id,
                    installPath: installPath,
                    readFromFolder: entry["readFromFolder"]?.stringValue,
                    version: entry["version"]?.stringValue,
                    scope: entry["scope"]?.stringValue,
                    enabled: entry["enabled"]?.boolValue,
                    projectPath: entry["projectPath"]?.stringValue
                ))
        }
        return Result(plugins: plugins, problems: problems)
    }
}

/// Names passed to the CLI or shown as ids must match a strict pattern (no spaces, quotes, `/`, leading `-`).
public enum NameValidator {
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128, let first = name.unicodeScalars.first,
            isAlnum(first)
        else { return false }
        return name.unicodeScalars.allSatisfy { isAlnum($0) || $0 == "." || $0 == "_" || $0 == "-" }
    }

    /// `name` or `name@origin`, each part a valid name.
    public static func isValidPluginId(_ id: String) -> Bool {
        let parts = id.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { isValidName(String($0)) }
    }

    private static func isAlnum(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
    }
}
