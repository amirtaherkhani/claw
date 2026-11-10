import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private func systemUnlink(_ path: String) -> Int32 { unlink(path) }
private func systemRename(_ from: String, _ to: String) -> Int32 { rename(from, to) }

/// The only place the write layer may delete or replace a file (NFR-SAFE, ROADMAP M2.13). A test can watch every
/// call through `observer`; `NoHardDeleteTests` checks that nothing else in `Write`, `Plan` or `Commands` calls
/// `rename`, `unlink` or `removeItem` directly.
enum Disk {
    enum Operation: Sendable, Equatable {
        case unlink(String)
        case rename(String, String)
    }

    /// Sees each operation before it runs. `onDedicatedThread` carries it to the threads the pipeline starts.
    @TaskLocal static var observer: (@Sendable (Operation) -> Void)?

    /// For Claw's own temporary files only.
    @discardableResult
    static func unlink(_ path: String) -> Int32 {
        observer?(.unlink(path))
        return systemUnlink(path)
    }

    /// Replaces `to` when it exists: only the atomic write does that, after the backup kept the original.
    @discardableResult
    static func rename(_ from: String, _ to: String) -> Int32 {
        observer?(.rename(from, to))
        return systemRename(from, to)
    }
}
