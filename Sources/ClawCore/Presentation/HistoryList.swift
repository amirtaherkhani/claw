import Foundation

/// One Apply as History shows it (PRD F12, ROADMAP M4.4).
public struct HistoryRow: Sendable, Equatable, Identifiable {
    /// The backup id, which is also the Apply's id.
    public let id: String
    public let title: String
    /// When it ran, as recorded.
    public let time: String
    /// Files and folders it changed, with `~` for the home folder.
    public let files: [String]
    public let result: BackupManifest.Status

    /// `time` as a date, for the person's own format. `nil` when the record holds something else.
    public var date: Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter.date(from: time)
    }

    /// Only a finished Apply has a full backup to put back.
    public var canRestore: Bool { result == .applied }
    public var isRestore: Bool { title.hasPrefix("Restore ") }
}

/// Which rows History shows.
public enum HistoryFilter: String, Sendable, CaseIterable {
    case all, applied, restores, undone
}

public enum HistoryList {
    /// Every recorded Apply, newest first. A line History cannot read is reported, never fatal.
    public static func rows(store: BackupStore, home: String) -> (rows: [HistoryRow], problems: [String]) {
        do {
            let (entries, problems) = try store.history.entries()
            let rows = entries.reversed().map { entry in
                HistoryRow(
                    id: entry.backupId, title: entry.title, time: entry.time,
                    files: entry.files.map { ItemPresentation.abbreviate($0, home: home) }, result: entry.result)
            }
            return (rows, problems.map(\.message))
        } catch {
            return ([], ["History could not be read: \(error)"])
        }
    }

    public static func filter(_ rows: [HistoryRow], query: String, filter: HistoryFilter) -> [HistoryRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return rows.filter { row in
            let kept: Bool
            switch filter {
            case .all: kept = true
            case .applied: kept = row.result == .applied && !row.isRestore
            case .restores: kept = row.isRestore
            case .undone: kept = row.result != .applied
            }
            let text = ([row.title, row.time, row.id] + row.files).joined(separator: " ").lowercased()
            return kept && words.allSatisfy { text.contains($0) }
        }
    }
}

/// A file or folder that changed after the backup: `path` is shown, `file` is what `accept` takes.
public struct Conflict: Sendable, Equatable, Identifiable {
    public let path: String
    public let file: String
    public let reason: String
    public var id: String { file }
}

/// What restoring one backup would put back (FR-F12-3, TECHNICAL-DESIGN section 9.7). Building it reads files and
/// writes nothing. A file changed after the backup is a conflict, left out until the person accepts it.
public struct RestorePreview: Sendable, Equatable {
    public let backupId: String
    /// Each file put back, with its diff (JSON masked, other files as sizes).
    public let files: [ReviewFile]
    /// Files the Apply created, which move aside into the new backup.
    public let movedAside: [String]
    public let conflicts: [Conflict]
    /// Already as the backup has them, with `~` for the home folder.
    public let alreadyRestored: [String]
    /// Hooks taken back out of Claw's stash.
    public let stashCount: Int
    /// Paths the person chose to restore over a change made after the backup.
    public let accepted: Set<String>
    let plan: RestorePlan

    /// Ready, and there is something to put back.
    public var canRestore: Bool {
        plan.isComplete && plan.changes.contains { !$0.edits.isEmpty || !$0.moves.isEmpty || $0.stash != nil }
    }

    public static func make(
        id: String, accept: Set<String> = [], store: BackupStore, stash: HookStash, home: String
    ) throws -> RestorePreview {
        let plan = try Restorer(store: store, stash: stash).plan(id: id, accept: accept)
        let short = { (path: String) in ItemPresentation.abbreviate(path, home: home) }
        let files = plan.changes.flatMap(\.edits).map { edit in
            ReviewFile(
                id: edit.file, path: short(edit.file), reason: edit.reason,
                lines: Review.diffLines(ChangeView.lines(file: edit.file, before: edit.before, after: edit.after)))
        }
        return RestorePreview(
            backupId: id, files: files, movedAside: plan.changes.flatMap(\.moves).map(short),
            conflicts: plan.conflicts.map { Conflict(path: short($0.path), file: $0.path, reason: $0.reason) },
            alreadyRestored: plan.alreadyRestored.map(short),
            stashCount: plan.changes.compactMap(\.stash).count, accepted: accept, plan: plan)
    }

    /// The restore could not start; nothing was written.
    public static func cannotStart(_ preview: RestorePreview, reason: String) -> ApplyOutcome {
        ApplyOutcome.notWritten(
            [ApplyOutcome.Subject(id: preview.backupId, title: "Restore \(preview.backupId)", effect: .newSession)],
            kind: .refused, detail: reason)
    }

    /// Puts the backup back through the Apply pipeline, so the restore gets its own backup first and a line in
    /// History. A preview with a conflict writes nothing.
    public static func run(
        _ preview: RestorePreview, pipeline: ApplyPipeline, home: String, date: Date = Date()
    ) async -> ApplyOutcome {
        let title = "Restore \(preview.backupId)"
        let subject = ApplyOutcome.Subject(id: preview.backupId, title: title, effect: .newSession)
        guard preview.plan.isComplete else {
            return ApplyOutcome.notWritten(
                [subject], kind: .refused,
                detail: "Some files changed after the backup. Look at each one and accept it, or leave it as it is.")
        }
        guard preview.canRestore else {
            return ApplyOutcome.notWritten([subject], kind: .refused, detail: "Everything is already as the backup has it.")
        }
        let intent = JSONValue.object([
            "kind": .string("restore"), "id": .string(preview.backupId),
            "accept": .array(preview.accepted.sorted().map(JSONValue.string)),
        ])
        return await ApplyOutcome.execute(
            preview.plan.changes, subjects: [subject], title: title, intent: intent, pipeline: pipeline, home: home,
            date: date, appliedHeadline: "Restored")
    }
}
