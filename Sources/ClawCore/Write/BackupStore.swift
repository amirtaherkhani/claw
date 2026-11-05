import Foundation

public struct BackupError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

/// `manifest.json` of one backup (TECHNICAL-DESIGN section 9.4). It holds hashes and paths, never file contents.
public struct BackupManifest: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case inProgress = "in-progress"
        case applied
        case rolledBack = "rolled-back"
        case failed
    }

    public struct Version: Codable, Sendable, Equatable {
        public var version: String?
    }

    public struct File: Codable, Sendable, Equatable {
        public let path: String
        public let existed: Bool
        public let sha256Before: String?
        public var sha256After: String?
        /// Permission bits, so Restore can bring back a file that is gone.
        public let mode: Int?
    }

    public struct Move: Codable, Sendable, Equatable {
        public let from: String
        /// Relative to the backup folder.
        public let to: String
        /// Original permission bits by path inside the moved item; `""` is the item itself.
        public let modes: [String: Int]
    }

    public var schema = 1
    public let id: String
    public var status: Status
    public let app: Version
    public let claudeCode: Version
    public let operations: [JSONValue]
    public var files: [File] = []
    public var moves: [Move] = []
    public var cli: [JSONValue] = []
    public var stash: [JSONValue] = []
}

/// Where backups live: `~/.claude.bak/<time>/`, folders 0700 and files 0600 because they may hold secrets
/// (`NFR-SEC-4`). Nothing here deletes a backup (`FR-F12-5`).
public struct BackupStore: Sendable {
    public let root: String

    init(root: String) { self.root = root }

    public init(environment: ClaudeEnvironment) throws {
        try self.init(root: joinPath(environment.home, ".claude.bak"), environment: environment)
    }

    /// A chosen folder. Claude Code's own `backups/` folder is refused (`FR-F12-6`).
    public init(root: String, environment: ClaudeEnvironment) throws {
        let theirs = joinPath(environment.configDir, "backups")
        guard root != theirs, !root.hasPrefix(theirs + "/") else {
            throw BackupError(reason: "\(theirs) belongs to Claude Code")
        }
        self.root = root
    }

    /// Creates the folder and writes an `in-progress` manifest, before anything is changed.
    public func start(
        date: Date = Date(), appVersion: String, claudeVersion: String?, operations: [JSONValue]
    ) throws -> BackupSession {
        try PrivateFiles.makeFolder(root)
        let name = Self.timestamp(date)
        for attempt in 1...1000 {
            let id = attempt == 1 ? name : "\(name)-\(attempt)"
            let folder = joinPath(root, id)
            guard mkdir(folder, 0o700) == 0 else {
                if errno == EEXIST { continue }
                throw BackupError(reason: "cannot create \(folder): \(String(cString: strerror(errno)))")
            }
            let manifest = BackupManifest(
                id: id, status: .inProgress, app: .init(version: appVersion), claudeCode: .init(version: claudeVersion),
                operations: operations)
            var session = BackupSession(folder: folder, manifest: manifest)
            try session.save()
            return session
        }
        throw BackupError(reason: "too many backups in one second")
    }

    /// Backups with a manifest, oldest first.
    public func ids() throws -> [String] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: root).sorted().filter {
            FileManager.default.fileExists(atPath: joinPath(root, $0, "manifest.json"))
        }
    }

    public func manifest(id: String) throws -> BackupManifest {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
            throw BackupError(reason: "not a backup id: \(id)")
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: joinPath(root, id, "manifest.json")))
            try StrictJSON.validate(data)
            return try JSONDecoder().decode(BackupManifest.self, from: data)
        } catch {
            throw BackupError(reason: "cannot read the manifest of \(id)")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.string(from: date)
    }
}

/// One Apply's backup while it runs. Every change is saved to the manifest at once, so recovery sees it after a crash.
public struct BackupSession: Sendable {
    public let folder: String
    public private(set) var manifest: BackupManifest
    private var savedHash: String?

    init(folder: String, manifest: BackupManifest) {
        self.folder = folder
        self.manifest = manifest
    }

    /// Copies a file under `files/` before it is changed. A file that does not exist yet is recorded as such.
    public mutating func keepOriginal(of path: String) throws {
        try Self.check(path)
        guard !manifest.files.contains(where: { $0.path == path }) else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            manifest.files.append(.init(path: path, existed: false, sha256Before: nil, sha256After: nil, mode: nil))
            return try save()
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw BackupError(reason: "cannot read \(path)")
        }
        let copy = folder + "/files" + path
        try PrivateFiles.makeFolder((copy as NSString).deletingLastPathComponent)
        try AtomicWrite.write(data, to: copy, expectedSHA256: nil)
        var info = stat()
        let mode = stat(path, &info) == 0 ? Int(info.st_mode & 0o777) : nil
        manifest.files.append(
            .init(path: path, existed: true, sha256Before: SHA256.hex(data), sha256After: nil, mode: mode))
        try save()
    }

    /// The bytes kept for `path`, or `nil` when the file did not exist. A copy that no longer matches is an error.
    public func original(of path: String) throws -> Data? {
        guard let record = manifest.files.first(where: { $0.path == path }) else {
            throw BackupError(reason: "not in this backup: \(path)")
        }
        guard record.existed else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: folder + "/files" + path)),
            SHA256.hex(data) == record.sha256Before
        else { throw BackupError(reason: "the kept copy of \(path) is missing or changed") }
        return data
    }

    public mutating func recordResult(of path: String, sha256After: String) throws {
        guard let index = manifest.files.firstIndex(where: { $0.path == path }) else {
            throw BackupError(reason: "not in this backup: \(path)")
        }
        manifest.files[index].sha256After = sha256After
        try save()
    }

    /// Moves a file or folder under `removed/`: removal never deletes (`NFR-SAFE-3`). The manifest is saved first,
    /// so a crash between the two steps leaves a record, not a lost item.
    public mutating func moveAway(_ path: String) throws {
        try Self.check(path)
        var info = stat()
        guard lstat(path, &info) == 0 else { throw BackupError(reason: "nothing to remove at \(path)") }
        let relative = "removed" + path
        let destination = joinPath(folder, relative)
        try PrivateFiles.makeFolder((destination as NSString).deletingLastPathComponent)
        manifest.moves.append(.init(from: path, to: relative, modes: PrivateFiles.modes(under: path)))
        try save()
        guard rename(path, destination) == 0 else {
            let reason = String(cString: strerror(errno))
            manifest.moves.removeLast()
            try save()
            throw BackupError(reason: "cannot move \(path): \(reason)")
        }
        PrivateFiles.tighten(destination)
    }

    public mutating func finish(_ status: BackupManifest.Status) throws {
        manifest.status = status
        try save()
    }

    mutating func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try AtomicWrite.write(data, to: joinPath(folder, "manifest.json"), expectedSHA256: savedHash)
        savedHash = SHA256.hex(data)
    }

    /// Paths are mirrored inside the backup, so one that could climb out of it is refused.
    private static func check(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.hasPrefix("/"), !parts.contains("."), !parts.contains("..") else {
            throw BackupError(reason: "not a plain absolute path: \(path)")
        }
    }
}

private enum PrivateFiles {
    /// Creates a folder and its parents with mode 0700. The last folder is made private even if it already existed.
    static func makeFolder(_ path: String) throws {
        do {
            try FileManager.default.createDirectory(
                atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            throw BackupError(reason: "cannot create \(path)")
        }
    }

    /// Permission bits of an item and everything inside it. Links have no bits of their own.
    static func modes(under path: String) -> [String: Int] {
        var result: [String: Int] = [:]
        walk(path, relative: "") { full, relative, info in
            result[relative] = Int(info.st_mode & 0o777)
        }
        return result
    }

    static func tighten(_ path: String) {
        walk(path, relative: "") { full, _, info in
            chmod(full, info.st_mode & S_IFMT == S_IFDIR ? 0o700 : 0o600)
        }
    }

    /// Visits a folder before its contents and never follows a link.
    private static func walk(_ path: String, relative: String, _ visit: (String, String, stat) -> Void) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK else { return }
        visit(path, relative, info)
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
            walk(joinPath(path, name), relative: relative.isEmpty ? name : joinPath(relative, name), visit)
        }
    }
}
