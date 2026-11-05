import Foundation

/// Everything the scanner may do with the disk. There are no write methods by design:
/// scanning is read-only by construction (PRD F02). Any call can block with no limit (`docs/spikes.md` F9),
/// so scans make them through `StoppableFileSystem`, off the Swift concurrency pool.
public protocol ReadonlyFileSystem: Sendable {
    /// File contents, or `nil` when the file does not exist.
    func readFile(_ path: String) throws -> Data?
    /// Sorted entry names, or `nil` when the directory does not exist.
    func contentsOfDirectory(_ path: String) throws -> [String]?
    func isDirectory(_ path: String) -> Bool
    func fileExists(_ path: String) -> Bool
    /// The path with symlinks resolved; the input path when it cannot be resolved.
    func resolvingSymlinks(_ path: String) -> String
    /// Last modification time, or `nil` when unknown.
    func modificationDate(_ path: String) -> Date?
}

extension ReadonlyFileSystem {
    public func modificationDate(_ path: String) -> Date? { nil }
}

public struct LocalFileSystem: ReadonlyFileSystem {
    public init() {}

    public func readFile(_ path: String) throws -> Data? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func contentsOfDirectory(_ path: String) throws -> [String]? {
        guard isDirectory(path) else { return nil }
        return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// `realpath` of the deepest part that exists, with the rest added back. Foundation's resolver drops
    /// `/private` from a path that exists and keeps it on one that does not, so the two would not compare (F11).
    public func resolvingSymlinks(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL.path
        var missing: [String] = []
        while true {
            if let resolved = realpath(existing, nil) {
                defer { free(resolved) }
                return missing.reversed().reduce(String(cString: resolved)) { joinPath($0, $1) }
            }
            guard existing != "/", !existing.isEmpty else { return path }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
    }

    public func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}

/// Joins path components with `/`, ignoring empty components.
public func joinPath(_ base: String, _ components: String...) -> String {
    components.reduce(base) { partial, component in
        guard !component.isEmpty else { return partial }
        return partial.hasSuffix("/") ? partial + component : partial + "/" + component
    }
}
