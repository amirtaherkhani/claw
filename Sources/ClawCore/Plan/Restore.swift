import Foundation

public struct RestoreConflict: Sendable, Equatable {
    public let path: String
    public let reason: String
}

/// What restoring a backup would do, with the changes ready for `ApplyPipeline`.
public struct RestorePlan: Sendable, Equatable {
    public let backupId: String
    /// The same `PlannedChange`s an Apply runs, so a restore gets its own new backup first (FR-F12-3).
    public let changes: [PlannedChange]
    /// Files and folders left out because they changed after the backup. Pass them in `accept` after showing the diff.
    public let conflicts: [RestoreConflict]
    /// Already as the backup has them.
    public let alreadyRestored: [String]
    /// Every path the changes write or move.
    public let files: [String]

    public var isComplete: Bool { conflicts.isEmpty }
}

/// Builds the plan that puts a backup's files back (TECHNICAL-DESIGN section 9.7). It writes nothing. A file that
/// changed after the backup is only included when the caller names it in `accept`, so it never goes unseen.
public struct Restorer: Sendable {
    private let store: BackupStore
    private let stash: HookStash

    public init(store: BackupStore, stash: HookStash) {
        self.store = store
        self.stash = stash
    }

    public func plan(id: String, accept: Set<String> = []) throws -> RestorePlan {
        let manifest = try store.manifest(id: id)
        guard manifest.status == .applied else {
            throw BackupError(reason: "\(id) is \(manifest.status.rawValue); only a finished apply can be restored")
        }
        let session = try store.resume(id: id)
        var edits: [FileEdit] = []
        var moves: [String] = []
        var folders: [FolderSpec] = []
        var conflicts: [RestoreConflict] = []
        var already: [String] = []

        for file in manifest.files {
            let current = try AtomicWrite.sha256(ofFile: file.path)
            let original = file.existed ? try session.original(of: file.path) : nil
            if current == file.sha256Before || Self.sameJSON(file.path, original) {
                // Byte for byte, or the same settings in another layout: `claude` rewrites a whole file in its own
                // format, so a later change it undid leaves the same values, not the same bytes.
                already.append(file.path)
                continue
            }
            if current != nil, current != file.sha256After, !accept.contains(file.path) {
                conflicts.append(RestoreConflict(path: file.path, reason: "changed after the backup"))
                continue
            }
            if file.existed {
                let original = try session.original(of: file.path) ?? Data()
                edits.append(
                    FileEdit(
                        file: file.path, before: try Self.bytes(file.path), after: original,
                        reason: "Restore \(file.path)", mode: file.mode))
            } else if current != nil {
                moves.append(file.path)
            }
        }

        for move in manifest.moves where move.created != true {
            let source = joinPath(session.folder, move.to)
            guard let tree = Self.tree(source) else {
                conflicts.append(RestoreConflict(path: move.from, reason: "the kept copy is missing"))
                continue
            }
            guard !tree.contains(where: \.isLink) else {
                conflicts.append(RestoreConflict(path: move.from, reason: "contains a link, which is not restored"))
                continue
            }
            let exists = Self.exists(move.from)
            var itemEdits: [FileEdit] = []
            var itemFolders: [FolderSpec] = []
            for entry in tree {
                let target = entry.relative.isEmpty ? move.from : joinPath(move.from, entry.relative)
                let mode = move.modes[entry.relative]
                if entry.isFolder {
                    if !Self.exists(target) { itemFolders.append(FolderSpec(path: target, mode: mode ?? 0o755)) }
                    continue
                }
                let wanted = try Data(contentsOf: URL(fileURLWithPath: joinPath(source, entry.relative)))
                let there = try Self.bytes(target)
                if there != wanted {
                    itemEdits.append(
                        FileEdit(file: target, before: there, after: wanted, reason: "Restore \(target)", mode: mode))
                }
            }
            if exists, !itemEdits.isEmpty || !itemFolders.isEmpty, !accept.contains(move.from) {
                conflicts.append(RestoreConflict(path: move.from, reason: "something is there now"))
            } else if itemEdits.isEmpty, itemFolders.isEmpty {
                already.append(move.from)
            } else {
                edits += itemEdits
                folders += itemFolders
            }
        }

        var changes = [
            PlannedChange(
                itemId: "restore:\(id)", enabled: nil, edits: edits, moves: moves, effect: .newSession, warnings: [],
                folders: folders)
        ]
        let held = Set(try stash.entries().map(\.id))
        for case .string(let entry) in manifest.stash where held.contains(entry) {
            changes.append(
                PlannedChange(
                    itemId: "restore:\(id):\(entry)", enabled: nil, edits: [], effect: .newSession, warnings: [],
                    stash: .take(entry)))
        }
        return RestorePlan(
            backupId: id, changes: changes, conflicts: conflicts, alreadyRestored: already,
            files: edits.map(\.file) + moves + folders.map(\.path))
    }

    private struct Entry {
        let relative: String
        let isFolder: Bool
        let isLink: Bool
    }

    /// The item and everything under it, folders before their contents. Links are reported, never followed.
    private static func tree(_ path: String, relative: String = "") -> [Entry]? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if info.st_mode & S_IFMT == S_IFLNK { return [Entry(relative: relative, isFolder: false, isLink: true)] }
        guard info.st_mode & S_IFMT == S_IFDIR else { return [Entry(relative: relative, isFolder: false, isLink: false)] }
        var result = [Entry(relative: relative, isFolder: true, isLink: false)]
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() {
            guard let child = tree(joinPath(path, name), relative: relative.isEmpty ? name : joinPath(relative, name)) else {
                continue
            }
            result += child
        }
        return result
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Both are JSON and hold the same values, in any key order or layout.
    private static func sameJSON(_ path: String, _ original: Data?) -> Bool {
        guard path.hasSuffix(".json"), let original, let now = try? bytes(path),
            let a = try? JSONValue.parse(now), let b = try? JSONValue.parse(original)
        else { return false }
        return a == b
    }

    private static func bytes(_ path: String) throws -> Data? {
        guard exists(path) else { return nil }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw BackupError(reason: "cannot read \(path)")
        }
    }
}
