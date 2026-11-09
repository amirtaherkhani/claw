import Foundation

/// The points of an Apply, in order. Tests stop at each one.
public enum ApplyStep: String, CaseIterable, Sendable {
    case backupStarted, originalsKept, moved, stashed, filesWritten, cliRan, verified
}

/// Thrown by a test's fault to stop the way a kill does: no rollback runs.
public struct ApplyCrash: Error, Equatable {
    public init() {}
}

public struct ApplyResult: Sendable, Equatable {
    public let backupId: String
    public let status: BackupManifest.Status
    /// Why it was undone. Never holds CLI output, which may quote a secret.
    public let failure: String?
    /// Files left alone by the rollback, because someone else changed them.
    public let kept: [String]
    /// Things that were not checked.
    public let notes: [String]
    public let effects: [PlanEffect]
}

/// Runs planned changes: stale check, backup, moves, writes, CLI steps, verify, and rollback on any failure
/// (TECHNICAL-DESIGN section 9.2). Every file here goes through `AtomicWrite`.
public struct ApplyPipeline: Sendable {
    private let environment: ClaudeEnvironment
    private let store: BackupStore
    private let stash: HookStash
    private let cli: ClaudeCLI?
    private let appVersion: String
    private let claudeVersion: String?
    private let fault: @Sendable (ApplyStep) throws -> Void

    public init(
        environment: ClaudeEnvironment, store: BackupStore, stash: HookStash, cli: ClaudeCLI?, appVersion: String,
        claudeVersion: String?
    ) {
        self.init(
            environment: environment, store: store, stash: stash, cli: cli, appVersion: appVersion,
            claudeVersion: claudeVersion, fault: { _ in })
    }

    init(
        environment: ClaudeEnvironment, store: BackupStore, stash: HookStash, cli: ClaudeCLI?, appVersion: String,
        claudeVersion: String?, fault: @escaping @Sendable (ApplyStep) throws -> Void
    ) {
        self.environment = environment
        self.store = store
        self.stash = stash
        self.cli = cli
        self.appVersion = appVersion
        self.claudeVersion = claudeVersion
        self.fault = fault
    }

    /// `replan` rebuilds the changes from the files as they are now. A running Claude Code rewrites `.claude.json`
    /// often, so a stale `.claude.json` is planned again, up to three tries (section 9.3).
    public func apply(
        _ changes: [PlannedChange], title: String, date: Date = Date(),
        replan: (@Sendable () throws -> [PlannedChange])? = nil
    ) async throws -> ApplyResult {
        var current = changes
        var attempt = 1
        while true {
            do {
                return try await once(current, title: title, date: date, lastTry: attempt == 3 || replan == nil)
            } catch let error as StaleFileError where error.file == environment.claudeJsonFile {
                guard attempt < 3, let replan else { throw error }
                current = try replan()
            } catch is RaceLost {
                guard let replan else { throw PlanError(reason: "Nothing to plan again with") }
                current = try replan()
            }
            attempt += 1
        }
    }

    /// The Apply was undone because `.claude.json` changed under it, and another try is allowed.
    private struct RaceLost: Error {}

    private final class Run: @unchecked Sendable {
        var session: BackupSession
        var written: Set<String> = []
        var cliStarted = false
        init(_ session: BackupSession) { self.session = session }
    }

    private struct Target {
        let file: String
        let before: Data?
        var after: Data
        var mode: Int?
    }

    private func once(_ changes: [PlannedChange], title: String, date: Date, lastTry: Bool) async throws -> ApplyResult {
        let targets = Self.merged(changes)
        let steps = changes.flatMap(\.cli)
        guard steps.isEmpty || cli != nil else { throw PlanError(reason: "The claude CLI is needed for this change") }
        let run: Run = try await onDedicatedThread { [self] in
            for target in targets {
                let expected = target.before.map(SHA256.hex)
                guard try AtomicWrite.sha256(ofFile: target.file) == expected else {
                    throw StaleFileError(file: target.file)
                }
            }
            let operations = changes.map { change -> JSONValue in
                var fields: [String: JSONValue] = ["itemId": .string(change.itemId)]
                fields["op"] = .string(change.enabled == nil ? "remove" : "setEnabled")
                if let enabled = change.enabled { fields["enabled"] = .bool(enabled) }
                return .object(fields)
            }
            return Run(
                try store.start(date: date, appVersion: appVersion, claudeVersion: claudeVersion, operations: operations))
        }
        do {
            try await onDedicatedThread { [self] in try prepare(run, changes, targets) }
            for step in steps {
                run.cliStarted = true
                try await cli?.run(step)
            }
            try fault(.cliRan)
            try await onDedicatedThread { [self] in try checkFiles(run, changes, targets) }
            let notes = try await checkPlugins(changes)
            try fault(.verified)
            try await onDedicatedThread { [self] in
                try run.session.finish(.applied)
                try store.history.append(entry(run, title: title, date: date, result: .applied))
                for case .take(let id) in changes.compactMap(\.stash) { try stash.take(id) }
            }
            return ApplyResult(
                backupId: run.session.manifest.id, status: .applied, failure: nil, kept: [], notes: notes,
                effects: Self.effects(changes))
        } catch let crash as ApplyCrash {
            throw crash
        } catch {
            let undone = try await onDedicatedThread { [self] in
                try rollBack(run, changes, targets, date: date)
            }
            let raced = (error as? StaleFileError)?.file == environment.claudeJsonFile
            if raced, !lastTry { throw RaceLost() }
            let reason =
                raced
                ? "Claude Code keeps rewriting \(environment.claudeJsonFile). Close its sessions and try again."
                : String(describing: error)
            return ApplyResult(
                backupId: run.session.manifest.id, status: undone.status, failure: reason, kept: undone.kept, notes: [],
                effects: [])
        }
    }

    private func prepare(_ run: Run, _ changes: [PlannedChange], _ targets: [Target]) throws {
        try fault(.backupStarted)
        for file in targets.map(\.file) + changes.flatMap(\.cliTouches) { try run.session.keepOriginal(of: file) }
        for target in targets { try run.session.recordResult(of: target.file, sha256After: SHA256.hex(target.after)) }
        try fault(.originalsKept)
        for path in changes.flatMap(\.moves) { try run.session.moveAway(path) }
        try fault(.moved)
        for case .put(let entry) in changes.compactMap(\.stash) {
            try run.session.recordStash(entry.id)
            try stash.put(entry)
        }
        try fault(.stashed)
        for folder in changes.flatMap(\.folders) {
            try FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true)
            chmod(folder.path, mode_t(folder.mode))
        }
        for target in targets {
            try AtomicWrite.write(
                target.after, to: target.file, expectedSHA256: target.before.map(SHA256.hex),
                newFileMode: target.mode.map { mode_t($0) }, beforeRename: {})
            run.written.insert(target.file)
        }
        try fault(.filesWritten)
    }

    /// Reads back what was written, and records what the CLI changed so a later failure can undo it.
    private func checkFiles(_ run: Run, _ changes: [PlannedChange], _ targets: [Target]) throws {
        try recordCliResults(run, changes)
        for target in targets {
            guard try AtomicWrite.sha256(ofFile: target.file) == SHA256.hex(target.after) else {
                throw StaleFileError(file: target.file)
            }
            guard target.file.hasSuffix(".json") else { continue }
            do {
                _ = try JSONValue.parse(target.after)
            } catch {
                throw PlanError(reason: "\(target.file) is not valid JSON after the change")
            }
        }
    }

    private func recordCliResults(_ run: Run, _ changes: [PlannedChange]) throws {
        for file in Set(changes.flatMap(\.cliTouches)) where !run.written.contains(file) {
            if let hash = try AtomicWrite.sha256(ofFile: file) { try run.session.recordResult(of: file, sha256After: hash) }
        }
    }

    /// Asks Claude Code itself: the CLI's merged view is the authority (section 6).
    private func checkPlugins(_ changes: [PlannedChange]) async throws -> [String] {
        let checks = changes.compactMap(\.pluginCheck)
        guard !checks.isEmpty else { return [] }
        guard let cli else { return ["The claude CLI was not available to confirm the plugin state."] }
        let plugins = try await cli.pluginList().plugins
        for check in checks {
            let found = plugins.filter { $0.id == check.id && (check.scope == nil || $0.scope == check.scope) }
            if let enabled = check.enabled {
                guard found.contains(where: { $0.enabled == enabled }) else {
                    throw PlanError(reason: "Claude Code does not report \(check.id) as \(enabled ? "on" : "off")")
                }
            } else if !found.isEmpty {
                throw PlanError(reason: "Claude Code still lists \(check.id)")
            }
        }
        return []
    }

    private func rollBack(
        _ run: Run, _ changes: [PlannedChange], _ targets: [Target], date: Date
    ) throws -> (status: BackupManifest.Status, kept: [String]) {
        for target in targets where !run.written.contains(target.file) { run.session.forget(target.file) }
        if run.cliStarted {
            try recordCliResults(run, changes)
        } else {
            for file in changes.flatMap(\.cliTouches) where !run.written.contains(file) { run.session.forget(file) }
        }
        try run.session.save()
        let id = run.session.manifest.id
        let result = try store.rollBack(id: id, date: date, title: "Undid a change that failed", stash: stash)
        return (try store.manifest(id: id).status, result.kept)
    }

    private func entry(_ run: Run, title: String, date: Date, result: BackupManifest.Status) -> HistoryEntry {
        let manifest = run.session.manifest
        return HistoryEntry(
            id: manifest.id, time: BackupStore.timestamp(date), title: title,
            files: manifest.files.map(\.path) + manifest.moves.map(\.from), backupId: manifest.id, result: result)
    }

    /// One target per file: the first `before`, the last `after`.
    private static func merged(_ changes: [PlannedChange]) -> [Target] {
        var targets: [Target] = []
        for edit in changes.flatMap(\.edits) {
            if let index = targets.firstIndex(where: { $0.file == edit.file }) {
                targets[index].after = edit.after
            } else {
                targets.append(Target(file: edit.file, before: edit.before, after: edit.after, mode: edit.mode))
            }
        }
        return targets
    }

    private static func effects(_ changes: [PlannedChange]) -> [PlanEffect] {
        var seen: [PlanEffect] = []
        for effect in changes.map(\.effect) where !seen.contains(effect) { seen.append(effect) }
        return seen
    }
}
