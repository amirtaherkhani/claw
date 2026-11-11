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
        cli: ClaudeCLI?, appVersion: String, claudeVersion: String?, killAt: CrashPoint? = nil,
        scan: @escaping @Sendable () async -> ScanResult
    ) {
        self.environment = environment
        self.planner = Planner(environment: environment, fileSystem: fileSystem)
        self.store = store
        self.stash = stash
        self.pipeline = ApplyPipeline(
            environment: environment, store: store, stash: stash, cli: cli, appVersion: appVersion,
            claudeVersion: claudeVersion, killAt: killAt)
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
                [change], title: title, intent: Self.intent(request, itemId: item.id),
                replan: { [try Self.plan(request, item: item, with: self.planner, self.environment)] })
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
            let intent = JSONValue.object([
                "kind": .string("restore"), "id": .string(id), "accept": .array(accept.sorted().map(JSONValue.string)),
            ])
            let result = try await pipeline.apply(plan.changes, title: "Restore \(id)", intent: intent)
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

    // MARK: recovery (M2.16)

    public enum RecoveryChoice: String, Sendable, CaseIterable {
        /// Undo what the interrupted change did.
        case cancel
        /// Finish it: check again (step 3), or undo and make the same request again (steps 1 and 2).
        case `continue`
        /// Only for a change that was done: History gets its entry.
        case ok
    }

    /// Changes a crash left behind. Show each at start-up.
    public func interrupted() throws -> [InterruptedChange] { try store.interruptedChanges() }

    public func recover(id: String, choice: RecoveryChoice) async -> WriteCommandResult {
        do {
            guard let change = try store.interruptedChanges().first(where: { $0.id == id }) else {
                throw PlanError(reason: "\(id) is not an interrupted change")
            }
            switch choice {
            case .ok:
                guard change.step == .finish else { throw PlanError(reason: "\(id) did not finish: Cancel or Continue") }
                try store.acknowledge(id: id)
                return WriteCommandResult(output: "Recorded in History. Backup \(id)\n", exitCode: 0)
            case .cancel:
                guard change.canCancel else { throw PlanError(reason: "\(id) was done: there is nothing to cancel") }
                return Self.undone(try store.rollBack(id: id, stash: stash), title: "Undone.")
            case .continue:
                guard change.canContinue else { throw PlanError(reason: Self.whyNotContinue(change)) }
                return try await finish(change)
            }
        } catch {
            return Self.refused(error)
        }
    }

    private func finish(_ change: InterruptedChange) async throws -> WriteCommandResult {
        if change.step == .verify {
            let failures = try store.recheck(id: change.id)
            guard failures.isEmpty else {
                let lines = ["The check failed again; nothing was changed. Cancel undoes the change."] + failures
                return WriteCommandResult(output: lines.joined(separator: "\n") + "\n", exitCode: 1)
            }
            try store.markDone(id: change.id, title: "Checked and finished a change after Claw stopped")
            var lines = ["Checked and finished. Backup \(change.id)"]
            if try store.manifest(id: change.id).operations.contains(where: Self.isPluginOperation) {
                lines.append("Not checked: what Claude Code reports for the plugin; run claw scan to see it.")
            }
            return WriteCommandResult(output: lines.joined(separator: "\n") + "\n", exitCode: 0)
        }
        let intent = try store.manifest(id: change.id).intent
        let undone = try store.rollBack(
            id: change.id, title: "Undid an interrupted change, to make it again", stash: stash)
        guard undone.kept.isEmpty else {
            return Self.undone(undone, title: "Undone, but not made again: some files were changed elsewhere.")
        }
        let again: WriteCommandResult
        switch intent?["kind"]?.stringValue {
        case "restore":
            let accept = Set((intent?["accept"]?.arrayValue ?? []).compactMap(\.stringValue))
            again = await restore(id: intent?["id"]?.stringValue ?? "", accept: accept, dryRun: false)
        default:
            guard let request = Self.request(from: intent) else {
                throw PlanError(reason: "the change in \(change.id) cannot be made again")
            }
            again = await apply(request, dryRun: false)
        }
        return WriteCommandResult(
            output: "Undid the unfinished change \(change.id), then made it again:\n" + again.output,
            exitCode: again.exitCode)
    }

    private static func whyNotContinue(_ change: InterruptedChange) -> String {
        if change.step == .finish { return "\(change.id) was done: choose OK" }
        if !change.changedElsewhere.isEmpty {
            return "changed by another program since: \(change.changedElsewhere.joined(separator: ", ")). Cancel only"
        }
        return "\(change.id) does not record its request, so it cannot be made again. Cancel only"
    }

    private static func undone(_ result: RollbackResult, title: String) -> WriteCommandResult {
        var lines = ["\(title) Backup \(result.id)"]
        for path in result.kept { lines.append("Left alone, changed by someone else: \(path)") }
        return WriteCommandResult(output: lines.joined(separator: "\n") + "\n", exitCode: result.kept.isEmpty ? 0 : 1)
    }

    private static func isPluginOperation(_ operation: JSONValue) -> Bool {
        operation["itemId"]?.stringValue?.hasPrefix("\(Concept.plugins.rawValue):") == true
    }

    static func intent(_ request: ChangeRequest, itemId: String) -> JSONValue {
        var fields: [String: JSONValue] = [
            "kind": .string("change"), "action": .string(request.action.rawValue), "selector": .string(itemId),
            "scope": .string(request.scope.rawValue),
        ]
        if let project = request.project { fields["project"] = .string(project) }
        return .object(fields)
    }

    static func request(from intent: JSONValue?) -> ChangeRequest? {
        guard let intent, intent["kind"]?.stringValue == "change",
            let action = intent["action"]?.stringValue.flatMap(ChangeAction.init(rawValue:)),
            let selector = intent["selector"]?.stringValue,
            let scope = intent["scope"]?.stringValue.flatMap(SettingsScope.init(rawValue:))
        else { return nil }
        return ChangeRequest(action: action, selector: selector, scope: scope, project: intent["project"]?.stringValue)
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
            lines.append(change.effect.guidance)
        }
        return lines.joined(separator: "\n") + "\n"
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
