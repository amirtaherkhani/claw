import Foundation

/// One file a reviewed change writes, with its diff. JSON is shown with secrets masked and command arguments
/// hidden; any other file shows sizes only (`ChangeView`).
public struct ReviewFile: Sendable, Equatable, Identifiable {
    public let id: String
    /// The path, with the home folder shown as `~`.
    public let path: String
    public let reason: String
    public let lines: [DiffLine]
}

/// One queued change as Apply would make it (PRD F11, ROADMAP M4.2).
public struct ReviewEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let itemId: String
    public let concept: Concept
    public let title: String
    public let files: [ReviewFile]
    /// Files and folders that move to the backup.
    public let moves: [String]
    /// `claude` commands Apply runs, as shown text.
    public let commands: [String]
    /// What happens in Claw's hook stash, when anything does.
    public let stash: String?
    /// Warnings first, then when the change takes effect.
    public let notes: [String]
    public let effect: PlanEffect?
    /// Why this change cannot be applied. The rest of the review still shows.
    public let error: String?
}

/// What Apply would do with the queue: real diffs, the backup folder and a checklist. Building it reads files and
/// writes nothing.
public struct Review: Sendable, Equatable {
    public let entries: [ReviewEntry]
    /// The planned changes, in queue order, for Apply. Empty when any change cannot be planned.
    public let plans: [PlannedChange]
    public let backupFolder: String
    public let checklist: [String]
    /// Open sessions need `/reload-plugins` or a restart to see a plugin change.
    public let needsReloadPlugins: Bool

    public var canApply: Bool { !entries.isEmpty && entries.allSatisfy { $0.error == nil } }

    /// `make` on its own thread, reading the disk, so a slow file never blocks the caller (the app's main actor).
    public static func build(
        queue: ChangeQueue, items: [Item], environment: ClaudeEnvironment, writeScope: WriteScope?,
        activeProject: String?
    ) async -> Review {
        let work: @Sendable () -> Review = {
            make(
                queue: queue, items: items, planner: Planner(environment: environment, fileSystem: LocalFileSystem()),
                writeScope: writeScope, activeProject: activeProject, home: environment.home)
        }
        return (try? await onDedicatedThread(work)) ?? work()
    }

    public static func make(
        queue: ChangeQueue, items: [Item], planner: Planner, writeScope: WriteScope?, activeProject: String?,
        home: String, date: Date = Date()
    ) -> Review {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var requests: [Planner.Request] = []
        var requested: [Int] = []
        for (index, change) in queue.changes.enumerated() {
            guard let item = byId[change.itemId] else { continue }
            switch change.action {
            case .enable: requests.append(.setEnabled(item, true))
            case .disable: requests.append(.setEnabled(item, false))
            case .remove: requests.append(.remove(item, keepData: true))
            }
            requested.append(index)
        }
        let results = planner.plan(requests, writeScope: writeScope, activeProject: activeProject, date: date)
        var resultFor: [Int: Result<PlannedChange, PlanError>] = [:]
        for (position, index) in requested.enumerated() { resultFor[index] = results[position] }

        var entries: [ReviewEntry] = []
        var plans: [PlannedChange] = []
        for (index, change) in queue.changes.enumerated() {
            switch resultFor[index] {
            case .success(let plan):
                plans.append(plan)
                entries.append(entry(change, plan: plan, home: home))
            case .failure(let error):
                entries.append(failed(change, error.reason))
            case nil:
                entries.append(failed(change, "This item is no longer there. Scan again, then queue it again."))
            }
        }
        let canApply = !entries.isEmpty && entries.allSatisfy { $0.error == nil }
        let backupFolder = ItemPresentation.abbreviate(joinPath(home, ".claude.bak"), home: home) + "/‹time›/"
        var checklist = [
            "A backup is created first in \(backupFolder)",
            "Files are written atomically; keys Claw does not manage are kept.",
        ]
        if plans.contains(where: { !$0.moves.isEmpty }) {
            checklist.append("Removed files and folders move to the backup; nothing is deleted.")
        }
        if plans.contains(where: { !$0.cli.isEmpty }) {
            checklist.append("Some steps run the claude CLI; restoring the backup does not undo them.")
        }
        return Review(
            entries: entries, plans: canApply ? plans : [], backupFolder: backupFolder, checklist: checklist,
            needsReloadPlugins: plans.contains { $0.effect == .reloadPlugins })
    }

    private static func entry(_ change: PendingChange, plan: PlannedChange, home: String) -> ReviewEntry {
        let files = plan.edits.map { edit in
            ReviewFile(
                id: "\(change.id)|\(edit.file)", path: ItemPresentation.abbreviate(edit.file, home: home),
                reason: edit.reason,
                lines: diffLines(ChangeView.lines(file: edit.file, before: edit.before, after: edit.after)))
        }
        var stash: String?
        var notes = plan.warnings
        switch plan.stash {
        case .put:
            stash = "Kept in Claw's stash, so you can turn it back on"
            notes.append(
                "Claude Code has no switch for one hook, so Claw takes the entry out and keeps a copy to put back.")
        case .take: stash = "Taken back from Claw's stash"
        case nil: break
        }
        notes.append(plan.effect.guidance)
        return ReviewEntry(
            id: change.id, itemId: change.itemId, concept: change.concept, title: change.title, files: files,
            moves: plan.moves.map { ItemPresentation.abbreviate($0, home: home) },
            commands: plan.cli.map { "claude " + $0.argv.joined(separator: " ") }, stash: stash, notes: notes,
            effect: plan.effect, error: nil)
    }

    private static func failed(_ change: PendingChange, _ reason: String) -> ReviewEntry {
        ReviewEntry(
            id: change.id, itemId: change.itemId, concept: change.concept, title: change.title, files: [], moves: [],
            commands: [], stash: nil, notes: [], effect: nil, error: reason)
    }

    /// `ChangeView` lines (`- `, `+ `, `  `) as typed lines.
    static func diffLines(_ lines: [String]) -> [DiffLine] {
        lines.enumerated().map { index, line in
            let text = String(line.dropFirst(2))
            switch line.prefix(2) {
            case "- ": return DiffLine(.removed, text, id: index)
            case "+ ": return DiffLine(.added, text, id: index)
            default: return DiffLine(text.hasPrefix("(") ? .note : .context, text, id: index)
            }
        }
    }
}

extension PlanEffect {
    /// When a running Claude Code session sees the change [V S4, TECHNICAL-DESIGN section 3.4].
    public var guidance: String {
        switch self {
        case .live: "Takes effect right away."
        case .reloadPlugins: "Run /reload-plugins in Claude Code to see it."
        case .afterClear: "Takes effect after /clear in Claude Code."
        case .newSession: "Takes effect in a new Claude Code session."
        }
    }
}
