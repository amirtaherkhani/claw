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

/// The step an interrupted change reached (M2.16, the owner's table in `docs/NEXT-STEPS.md`).
public enum InterruptedStep: String, Sendable, Equatable {
    /// Nothing was changed yet.
    case backup
    /// Some files may be new, some old.
    case write
    /// Every file was written; the check did not run or did not finish.
    case verify
    /// The change was done; only History did not get it.
    case finish
}

/// One change to show at start-up, with what the user may do about it.
public struct InterruptedChange: Sendable, Equatable {
    public let id: String
    public let step: InterruptedStep
    /// Files another program changed after the crash: Continue is not offered, and Cancel leaves them alone.
    public let changedElsewhere: [String]
    /// The request can be made again. False for older backups that did not record it.
    public let repeatable: Bool

    /// Cancel and Continue for steps 1 to 3; only OK for a change that was done.
    public var canCancel: Bool { step != .finish }
    public var canContinue: Bool {
        guard step != .finish, changedElsewhere.isEmpty else { return false }
        return step == .verify || repeatable
    }

    public var message: String {
        switch step {
        case .backup: "The last change didn't finish. Nothing was changed yet."
        case .write: "The last change didn't finish. Some files may already be changed."
        case .verify: "The last change wasn't checked."
        case .finish: "The last change was done."
        }
    }
}

extension BackupStore {
    /// Changes a crash left behind, oldest first: unfinished ones, and finished ones History does not have.
    public func interruptedChanges() throws -> [InterruptedChange] {
        let recorded = Set((try? history.entries().entries.map(\.backupId)) ?? [])
        var found: [InterruptedChange] = []
        for id in try ids() {
            let manifest = try manifest(id: id)
            switch manifest.status {
            case .applied where !recorded.contains(id):
                found.append(InterruptedChange(id: id, step: .finish, changedElsewhere: [], repeatable: false))
            case .inProgress:
                found.append(try interruptedChange(manifest))
            default:
                continue
            }
        }
        return found
    }

    private func interruptedChange(_ manifest: BackupManifest) throws -> InterruptedChange {
        let folder = joinPath(root, manifest.id)
        var states: [RecoveryFileState] = []
        var elsewhere: [String] = []
        for file in manifest.files {
            let state = try recoveryState(of: file)
            states.append(state)
            if state == .changedElsewhere { elsewhere.append(file.path) }
        }
        let moved = manifest.moves.filter { FileManager.default.fileExists(atPath: joinPath(folder, $0.to)) }
        let planned = manifest.files.filter { $0.sha256After != nil }
        let step: InterruptedStep
        if states.allSatisfy({ $0 == .untouched }), moved.isEmpty, manifest.stash.isEmpty {
            step = .backup
        } else if !planned.isEmpty, planned.count == manifest.files.count, states.allSatisfy({ $0 == .written }),
            moved.count == manifest.moves.count
        {
            step = .verify
        } else {
            step = .write
        }
        return InterruptedChange(
            id: manifest.id, step: step, changedElsewhere: elsewhere, repeatable: manifest.intent != nil)
    }

    /// The check of step 3, again: every file holds exactly what the change wrote, and JSON files parse.
    public func recheck(id: String) throws -> [String] {
        var failures: [String] = []
        for file in try manifest(id: id).files {
            guard try recoveryState(of: file) == .written else {
                failures.append("\(file.path) does not hold what the change wrote")
                continue
            }
            guard file.path.hasSuffix(".json"), let data = FileManager.default.contents(atPath: file.path) else {
                continue
            }
            if (try? JSONValue.parse(data)) == nil { failures.append("\(file.path) is not valid JSON") }
        }
        return failures
    }

    /// Marks an interrupted change done after its check passed again, and adds it to History.
    public func markDone(id: String, title: String, date: Date = Date()) throws {
        var session = try resume(id: id)
        guard session.manifest.status == .inProgress else { throw BackupError(reason: "\(id) is not interrupted") }
        try session.finish(.applied)
        try acknowledge(id: id, title: title, date: date)
    }

    /// OK on "The last change was done": History gets the entry it missed.
    public func acknowledge(id: String, title: String = "A change finished before Claw stopped", date: Date = Date())
        throws
    {
        let manifest = try manifest(id: id)
        guard manifest.status == .applied else { throw BackupError(reason: "\(id) was not done") }
        let recorded = Set(try history.entries().entries.map(\.backupId))
        guard !recorded.contains(id) else { return }
        try history.append(
            HistoryEntry(
                id: id, time: Self.timestamp(date), title: title,
                files: manifest.files.map(\.path) + manifest.moves.map(\.from), backupId: id, result: .applied))
    }

    fileprivate func recoveryState(of file: BackupManifest.File) throws -> RecoveryFileState {
        let current = try AtomicWrite.sha256(ofFile: file.path)
        if current == file.sha256Before { return .untouched }
        if current != nil, current == file.sha256After { return .written }
        return .changedElsewhere
    }
}
