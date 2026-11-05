import Foundation

/// The file no longer holds what the scan saw, so the planned change no longer applies.
public struct StaleFileError: Error, Equatable, CustomStringConvertible {
    public let file: String
    public var description: String { "File changed since it was scanned: \(file)" }
}

public struct AtomicWriteError: Error, Equatable, CustomStringConvertible {
    public let file: String
    public let reason: String
    public var description: String { "\(file): \(reason)" }
}

/// Replaces a file so a reader, or a crash, sees the old bytes or the new ones, never a mix (`NFR-SAFE-1`,
/// TECHNICAL-DESIGN section 9.3). The hash check before the rename narrows the race with a running Claude Code
/// but cannot close it; the pipeline handles that for `~/.claude.json`.
public enum AtomicWrite {
    /// The hash of a file, or `nil` when there is no file.
    public static func sha256(ofFile path: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var isFolder: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
        guard !isFolder.boolValue else { throw AtomicWriteError(file: path, reason: "this is a folder") }
        do {
            return SHA256.hex(try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw AtomicWriteError(file: path, reason: "cannot be read: \(error.localizedDescription)")
        }
    }

    /// Writes `data` to `target`. `expectedSHA256` is the hash seen at scan time; `nil` means no file was there.
    /// A symlink stays a link and its destination is replaced. The file keeps its mode; a new file gets 0600.
    public static func write(_ data: Data, to target: String, expectedSHA256: String?) throws {
        try write(data, to: target, expectedSHA256: expectedSHA256, beforeRename: {})
    }

    static func write(_ data: Data, to target: String, expectedSHA256: String?, beforeRename: () -> Void) throws {
        let real = try resolved(target)
        func checkUnchanged() throws {
            guard try sha256(ofFile: real) == expectedSHA256 else { throw StaleFileError(file: target) }
        }
        try checkUnchanged()

        var info = stat()
        let mode = stat(real, &info) == 0 ? mode_t(info.st_mode) & 0o777 : 0o600
        let folder = (real as NSString).deletingLastPathComponent
        let name = (real as NSString).lastPathComponent
        let temporary = joinPath(folder, ".\(name).\(UUID().uuidString).tmp")

        try writeTemporary(data, to: temporary, mode: mode, target: target)
        do {
            beforeRename()
            try checkUnchanged()
            guard rename(temporary, real) == 0 else { throw failure(target, "cannot be replaced") }
        } catch {
            unlink(temporary)  // Our own temporary file, never user content.
            throw error
        }
        syncFolder(folder)
    }

    /// Follows links. A link with nothing behind it is refused: a rename would replace the link itself.
    private static func resolved(_ target: String) throws -> String {
        var info = stat()
        guard lstat(target, &info) == 0 else { return target }
        guard let pointer = realpath(target, nil) else {
            throw AtomicWriteError(file: target, reason: "this link points to nothing")
        }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func writeTemporary(_ data: Data, to path: String, mode: mode_t, target: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, mode)
        guard descriptor >= 0 else { throw failure(target, "cannot create a file next to it") }
        do {
            defer { close(descriptor) }
            guard fchmod(descriptor, mode) == 0 else { throw failure(target, "cannot set the file mode") }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Foundation.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw failure(target, "cannot write") }
                    offset += written
                }
            }
            guard flush(descriptor) else { throw failure(target, "cannot flush to disk") }
        } catch {
            unlink(path)
            throw error
        }
    }

    /// On macOS `fsync` leaves data in the drive's cache; `F_FULLFSYNC` does not, where the drive supports it.
    private static func flush(_ descriptor: Int32) -> Bool {
        #if canImport(Darwin)
            if fcntl(descriptor, F_FULLFSYNC) == 0 { return true }
        #endif
        return fsync(descriptor) == 0
    }

    /// Makes the rename itself durable. The new bytes are already in place, so a failure here is not an error.
    private static func syncFolder(_ folder: String) {
        let descriptor = open(folder, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }

    private static func failure(_ file: String, _ what: String) -> AtomicWriteError {
        AtomicWriteError(file: file, reason: "\(what): \(String(cString: strerror(errno)))")
    }
}
