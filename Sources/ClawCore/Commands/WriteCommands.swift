import Foundation

public enum ChangeAction: String, Sendable, CaseIterable {
    case enable, disable, remove
}

/// One change asked for on the command line: an item (by id, or by name when the name is unique) and what to do.
public struct ChangeRequest: Sendable, Equatable {
    public let action: ChangeAction
    public let selector: String
    public let scope: SettingsScope
    public let project: String?

    public init(action: ChangeAction, selector: String, scope: SettingsScope = .user, project: String? = nil) {
        self.action = action
        self.selector = selector
        self.scope = scope
        self.project = project
    }
}

/// Text for the terminal and an exit code: 0 done, 1 failed and undone, 2 refused before anything was written.
public struct WriteCommandResult: Sendable, Equatable {
    public let output: String
    public let exitCode: Int32
}

/// The write commands of the `claw` CLI (`plan`, `apply`, `restore`, `history`) on top of the planner, the Apply
/// pipeline and the restorer. `plan` and `apply --dry-run` share one renderer, so a dry run prints what a real run
/// does. Output holds file paths and masked JSON only, never a secret value or a CLI output (NFR-SEC).
public struct WriteCommands: Sendable {
    private let environment: ClaudeEnvironment
    private let planner: Planner
    private let store: BackupStore
    private let stash: HookStash
    private let pipeline: ApplyPipeline
    private let scan: @Sendable () async -> ScanResult

    public init(
        environment: ClaudeEnvironment, fileSystem: any ReadonlyFileSystem, store: BackupStore, stash: HookStash,
        cli: ClaudeCLI?, appVersion: String, claudeVersion: String?, scan: @escaping @Sendable () async -> ScanResult
    ) {
        self.environment = environment
        self.planner = Planner(environment: environment, fileSystem: fileSystem)
        self.store = store
        self.stash = stash
        self.pipeline = ApplyPipeline(
            environment: environment, store: store, stash: stash, cli: cli, appVersion: appVersion,
            claudeVersion: claudeVersion)
        self.scan = scan
    }

    // MARK: plan and apply

    public func plan(_ request: ChangeRequest) async -> WriteCommandResult {
        do {
            let (change, _) = try await prepare(request)
            return WriteCommandResult(output: Self.render([change]), exitCode: 0)
        } catch {
            return Self.refused(error)
        }
    }

    public func apply(_ request: ChangeRequest, dryRun: Bool) async -> WriteCommandResult {
        do {
            let (change, item) = try await prepare(request)
            let text = Self.render([change])
            if dryRun { return WriteCommandResult(output: text, exitCode: 0) }
            let title = "\(request.action.rawValue.capitalized) \(item.name)"
            let result = try await pipeline.apply(
                [change], title: title, replan: { [try Self.plan(request, item: item, with: self.planner, self.environment)] })
            return Self.finish(text: text, result: result)
        } catch {
            return Self.refused(error)
        }
    }

    // MARK: restore and history

    public func restore(id: String, accept: Set<String>, dryRun: Bool) async -> WriteCommandResult {
        do {
            let plan = try Restorer(store: store, stash: stash).plan(id: id, accept: accept)
            if !plan.isComplete {
                var lines = ["Changed since backup \(id); nothing was written:"]
                for conflict in plan.conflicts { lines.append("  \(conflict.path): \(conflict.reason)") }
                lines.append("Look at them, then repeat with --accept <path> for each one you want restored over.")
                return WriteCommandResult(output: lines.joined(separator: "\n") + "\n", exitCode: 2)
            }
            let text = Self.render(plan.changes)
            if dryRun { return WriteCommandResult(output: text, exitCode: 0) }
            let result = try await pipeline.apply(plan.changes, title: "Restore \(id)")
            return Self.finish(text: text, result: result)
        } catch {
            return Self.refused(error)
        }
    }

    public func history() -> WriteCommandResult {
        do {
            let (entries, problems) = try store.history.entries()
            var lines =
                entries.isEmpty ? ["No changes yet."] : entries.map { "\($0.backupId)  \($0.result.rawValue)  \($0.title)" }
            for problem in problems { lines.append("\(problem.severity.rawValue): \(problem.message)") }
            return WriteCommandResult(output: lines.joined(separator: "\n") + "\n", exitCode: 0)
        } catch {
            return Self.refused(error)
        }
    }

    // MARK: building the change

    private func prepare(_ request: ChangeRequest) async throws -> (PlannedChange, Item) {
        let result = await scan()
        let item = try Self.find(request.selector, in: result.items)
        return (try Self.plan(request, item: item, with: planner, environment), item)
    }

    private static func find(_ selector: String, in items: [Item]) throws -> Item {
        if let exact = items.first(where: { $0.id == selector }) { return exact }
        let named = items.filter { $0.name == selector }
        switch named.count {
        case 0: throw PlanError(reason: "no item with the id or name \(selector)")
        case 1: return named[0]
        default:
            let ids = named.map { "  \($0.id)  (\($0.concept.rawValue), \($0.scope.rawValue))" }.joined(separator: "\n")
            throw PlanError(reason: "more than one item is named \(selector); use its id:\n\(ids)")
        }
    }

    private static func plan(_ request: ChangeRequest, item: Item, with planner: Planner, _ environment: ClaudeEnvironment)
        throws -> PlannedChange
    {
        switch request.action {
        case .remove: return try planner.remove(item)
        case .enable, .disable:
            if request.scope == .managed { throw PlanError(reason: "managed settings are read-only") }
            guard
                let writeScope = WriteScope.resolve(request.scope, environment: environment, activeProject: request.project)
            else { throw PlanError(reason: "the \(request.scope.rawValue) scope needs --project <path>") }
            return try planner.setEnabled(
                item, enabled: request.action == .enable, writeScope: writeScope, activeProject: request.project)
        }
    }

    // MARK: output

    static func render(_ changes: [PlannedChange]) -> String {
        var lines: [String] = []
        for change in changes {
            lines.append("Change: \(change.itemId)")
            for warning in change.warnings { lines.append("  warning: \(warning)") }
            for edit in change.edits {
                lines.append("--- \(edit.file)  (\(edit.reason))")
                lines += ChangeView.lines(file: edit.file, before: edit.before, after: edit.after)
            }
            for path in change.moves { lines.append("move to backup: \(path)") }
            for step in change.cli {
                lines.append("run: claude \(step.argv.joined(separator: " "))  (a restore does not undo this)")
            }
            if let stash = change.stash { lines.append("hook stash: \(stash)") }
            lines.append(effectText(change.effect))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func effectText(_ effect: PlanEffect) -> String {
        switch effect {
        case .live: return "Takes effect right away."
        case .reloadPlugins: return "Run /reload-plugins in Claude Code to see it."
        case .afterClear: return "Takes effect after /clear in Claude Code."
        case .newSession: return "Takes effect in a new Claude Code session."
        }
    }

    private static func finish(text: String, result: ApplyResult) -> WriteCommandResult {
        var lines = [text.trimmingCharacters(in: .newlines)]
        switch result.status {
        case .applied:
            lines.append("Applied. Backup \(result.backupId)")
        default:
            lines.append("Not applied (\(result.status.rawValue)); the files are as they were. Backup \(result.backupId)")
            if let failure = result.failure { lines.append("Reason: \(failure)") }
        }
        for path in result.kept { lines.append("Left alone, changed by someone else: \(path)") }
        for note in result.notes { lines.append("Not checked: \(note)") }
        return WriteCommandResult(output: lines.joined(separator: "\n") + "\n", exitCode: result.status == .applied ? 0 : 1)
    }

    private static func refused(_ error: Error) -> WriteCommandResult {
        WriteCommandResult(output: "claw: \(error)\n", exitCode: 2)
    }
}
