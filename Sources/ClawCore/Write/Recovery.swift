import Foundation

public enum RecoveryFileState: Sendable, Equatable {
    /// Still the bytes from before the Apply.
    case untouched
    /// Holds what the Apply meant to write.
    case written
    /// Neither: someone else changed it, so recovery must not overwrite it.
    case changedElsewhere
}

public struct RecoveryReport: Sendable, Equatable {
    public let id: String
    public let files: [String: RecoveryFileState]
}

public struct RollbackResult: Sendable, Equatable {
    public let id: String
    /// Items left as they are, because putting them back would overwrite someone's change.
    public let kept: [String]
}

/// Finds an Apply that never finished and undoes it (TECHNICAL-DESIGN section 9.4). A file is only changed when
/// its bytes prove it is what the Apply wrote; anything else is reported.
extension BackupStore {
    /// Backups left `in-progress`, oldest first. Check at start-up.
    public func interrupted() throws -> [String] {
        try ids().filter { try manifest(id: $0).status == .inProgress }
    }

    public func inspect(id: String) throws -> RecoveryReport {
        let manifest = try manifest(id: id)
        var files: [String: RecoveryFileState] = [:]
        for file in manifest.files { files[file.path] = try state(of: file) }
        return RecoveryReport(id: id, files: files)
    }

    /// Undoes an interrupted Apply. Safe to run again if it is cut short itself.
    public func rollBack(
        id: String, date: Date = Date(), title: String = "Undid a change that was interrupted", stash: HookStash? = nil
    ) throws -> RollbackResult {
        var session = try resume(id: id)
        guard session.manifest.status == .inProgress else {
            throw BackupError(reason: "\(id) is not an interrupted change")
        }
        var kept: [String] = []
        for move in session.manifest.moves where move.created != true {
            guard try putBack(move, folder: session.folder) else {
                kept.append(move.from)
                continue
            }
        }
        for file in session.manifest.files {
            switch try state(of: file) {
            case .untouched: continue
            case .changedElsewhere: kept.append(file.path)
            case .written:
                if let original = try session.original(of: file.path) {
                    try AtomicWrite.write(original, to: file.path, expectedSHA256: file.sha256After)
                } else {
                    try session.moveAway(file.path, created: true)
                }
            }
        }
        for case .string(let entry) in session.manifest.stash { try? stash?.take(entry) }
        let result: BackupManifest.Status = kept.isEmpty ? .rolledBack : .failed
        try session.finish(result)
        try history.append(
            HistoryEntry(
                id: id, time: Self.timestamp(date), title: title,
                files: session.manifest.files.map(\.path) + session.manifest.moves.map(\.from), backupId: id, result: result))
        return RollbackResult(id: id, kept: kept)
    }

    private func state(of file: BackupManifest.File) throws -> RecoveryFileState {
        let current = try AtomicWrite.sha256(ofFile: file.path)
        if current == file.sha256Before { return .untouched }
        if current != nil, current == file.sha256After { return .written }
        return .changedElsewhere
    }

    /// Returns false when the place is taken. A move that never happened needs nothing.
    private func putBack(_ move: BackupManifest.Move, folder: String) throws -> Bool {
        let source = joinPath(folder, move.to)
        guard FileManager.default.fileExists(atPath: source) else { return true }
        guard !FileManager.default.fileExists(atPath: move.from) else { return false }
        try? FileManager.default.createDirectory(
            atPath: (move.from as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard Disk.rename(source, move.from) == 0 else { throw BackupError(reason: "cannot put back \(move.from)") }
        PrivateFiles.restore(move.modes, under: move.from)
        return true
    }
}
