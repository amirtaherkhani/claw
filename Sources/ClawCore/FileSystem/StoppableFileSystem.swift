import Foundation

/// The scan's view of the disk. macOS can hold `open()` on a protected folder until its privacy dialog
/// is answered (`docs/spikes.md` F9), and nothing can interrupt a thread inside that call. So `run` does
/// the reading on a dedicated thread (F4) and walks away from it when the task is cancelled; the thread
/// ends by itself once the call returns. After that every call here refuses to touch the disk, so an
/// abandoned thread cannot read on and raise another dialog.
final class StoppableFileSystem: ReadonlyFileSystem, @unchecked Sendable {
    static let threadName = "claw.scan.reads"

    private let base: any ReadonlyFileSystem
    private let lock = NSLock()
    private var stopped = false
    private var running: (path: String, since: ContinuousClock.Instant)?

    init(_ base: any ReadonlyFileSystem) {
        self.base = base
    }

    /// Runs blocking work on its own thread. Returns `nil` as soon as the task is cancelled.
    func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T? {
        let once = ResumeOnce<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                once.set(continuation)
                Thread.detachNewThread {
                    Thread.current.name = Self.threadName
                    once.resume(work())
                }
            }
        } onCancel: {
            lock.withLock { stopped = true }
            once.resume(nil)
        }
    }

    /// The path of the call in progress, when it has been running for at least `limit`.
    func path(runningFor limit: Duration) -> String? {
        lock.withLock {
            guard let running, running.since.duration(to: .now) >= limit else { return nil }
            return running.path
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func timed<T>(_ path: String, _ call: () throws -> T) rethrows -> T {
        lock.withLock { running = (path, .now) }
        defer { lock.withLock { running = nil } }
        return try call()
    }

    func readFile(_ path: String) throws -> Data? {
        if isStopped { throw CancellationError() }
        return try timed(path) { try base.readFile(path) }
    }

    func contentsOfDirectory(_ path: String) throws -> [String]? {
        if isStopped { throw CancellationError() }
        return try timed(path) { try base.contentsOfDirectory(path) }
    }

    func isDirectory(_ path: String) -> Bool {
        !isStopped && timed(path) { base.isDirectory(path) }
    }

    func fileExists(_ path: String) -> Bool {
        !isStopped && timed(path) { base.fileExists(path) }
    }

    func resolvingSymlinks(_ path: String) -> String {
        isStopped ? path : timed(path) { base.resolvingSymlinks(path) }
    }

    func modificationDate(_ path: String) -> Date? {
        isStopped ? nil : timed(path) { base.modificationDate(path) }
    }

    func isExecutable(_ path: String) -> Bool {
        !isStopped && timed(path) { base.isExecutable(path) }
    }
}
