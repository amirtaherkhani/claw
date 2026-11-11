import Foundation

/// The points of an Apply, in order. Tests stop at each one.
public enum ApplyStep: String, CaseIterable, Sendable {
    case backupStarted, originalsKept, moved, stashed, filesWritten, cliRan, verified
}

/// Where a crash test kills the process for real (`CLAW_TEST_KILL_AT`, M2.16): in the backup, in the write, before
/// the check, and after the change is marked done but before History has it.
public enum CrashPoint: String, CaseIterable, Sendable {
    case backup, write, verify, finish

    var step: ApplyStep? {
        switch self {
        case .backup: .originalsKept
        case .write: .stashed
        case .verify: .filesWritten
        case .finish: nil
        }
    }

    func kill() -> Never {
        _ = raise(SIGKILL)
        fatalError("SIGKILL did not stop the process")
    }
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

    /// `killAt` is for crash tests only: the process kills itself there.
    public init(
        environment: ClaudeEnvironment, store: BackupStore, stash: HookStash, cli: ClaudeCLI?, appVersion: String,
        claudeVersion: String?, killAt: CrashPoint? = nil
    ) {
        self.init(
            environment: environment, store: store, stash: stash, cli: cli, appVersion: appVersion,
            claudeVersion: claudeVersion, fault: { step in if let killAt, killAt.step == step { killAt.kill() } })
        self.killAtFinish = killAt == .finish
    }

    private var killAtFinish = false

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
        _ changes: [PlannedChange], title: String, date: Date = Date(), intent: JSONValue? = nil,
        replan: (@Sendable () throws -> [PlannedChange])? = nil
    ) async throws -> ApplyResult {
        var current = changes
        var attempt = 1
        while true {
            do {
                return try await once(
                    current, title: title, date: date, intent: intent, lastTry: attempt == 3 || replan == nil)
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

    private func once(
        _ changes: [PlannedChange], title: String, date: Date, intent: JSONValue?, lastTry: Bool
    ) async throws -> ApplyResult {
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
                try store.start(
                    date: date, appVersion: appVersion, claudeVersion: claudeVersion, operations: operations,
                    intent: intent))
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
                if killAtFinish { CrashPoint.finish.kill() }
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
        let expected = changes.flatMap(\.expected)
        for target in targets {
            let promised = expected.filter { $0.file == target.file }
            if promised.isEmpty {
                guard try AtomicWrite.sha256(ofFile: target.file) == SHA256.hex(target.after) else {
                    throw StaleFileError(file: target.file)
                }
            } else {
                // `claude` rewrote a file Claw also wrote: it keeps Claw's values and adds its own, in its own format.
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.file)),
                    let now = try? JSONValue.parse(data), let written = try? JSONValue.parse(target.after),
                    Self.applying(promised, to: now) == Self.applying(promised, to: written)
                else { throw PlanError(reason: "\(target.file) does not hold Claw's change after the claude step") }
            }
            guard target.file.hasSuffix(".json") else { continue }
            do {
                _ = try JSONValue.parse(target.after)
            } catch {
                throw PlanError(reason: "\(target.file) is not valid JSON after the change")
            }
        }
        for value in expected {
            let data = try? Data(contentsOf: URL(fileURLWithPath: value.file))
            let now = data.flatMap { try? JSONValue.parse($0) }
            let found = value.path.reduce(now) { $0?[$1] }
            guard found == value.value else {
                let key = value.path.joined(separator: ".")
                throw PlanError(reason: "The claude step did not leave \(key) as planned in \(value.file)")
            }
        }
    }

    /// `value` with each promised key set to its promised value, so two files compare on everything else.
    private static func applying(_ promised: [ExpectedValue], to value: JSONValue) -> JSONValue {
        promised.reduce(value) { $0.setting($1.path, to: $1.value) }
    }

    /// What the CLI left, so a later failure or a Restore puts back what was there before it ran.
    private func recordCliResults(_ run: Run, _ changes: [PlannedChange]) throws {
        for file in Set(changes.flatMap(\.cliTouches)) {
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
