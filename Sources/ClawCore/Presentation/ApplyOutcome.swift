import Foundation

/// What Apply did with a reviewed queue (ROADMAP M4.3): the whole queue is one Apply, so every change shares the
/// result. Text here holds paths and plan reasons only, never a CLI output or a secret.
public struct ApplyOutcome: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// Written, checked and in History.
        case applied
        /// Written, then undone because a later step failed.
        case rolledBack
        /// A later step failed and the undo could not put every file back.
        case failed
        /// A file changed since the scan; nothing was written.
        case stale
        /// Nothing to apply, or a step it needs is missing; nothing was written.
        case refused
    }

    public struct Change: Sendable, Equatable, Identifiable {
        public enum State: String, Sendable {
            case applied, undone, notWritten
        }
        public let id: String
        public let title: String
        public let state: State
        /// When a running Claude Code sees it; only for an applied change.
        public let guidance: String?
    }

    public let kind: Kind
    public let headline: String
    /// Why it was undone or not written.
    public let detail: String?
    public let backupId: String?
    public let changes: [Change]
    /// Files the undo left alone because someone else changed them, with `~` for the home folder.
    public let kept: [String]
    /// Things that were not checked.
    public let notes: [String]
    /// The file that changed since the scan, with `~` for the home folder.
    public let staleFile: String?

    public var wroteNothing: Bool { kind == .stale || kind == .refused }

    /// Runs `review.plans` through `pipeline`. `replan` builds the plans again from the files as they are now; the
    /// pipeline uses it when Claude Code rewrites `.claude.json` during the Apply.
    public static func run(
        _ review: Review, pipeline: ApplyPipeline, home: String, confirmed: Set<String> = [],
        replan: (@Sendable () throws -> [PlannedChange])? = nil, date: Date = Date()
    ) async -> ApplyOutcome {
        let subjects = review.entries.map { Subject(id: $0.id, title: $0.title, guidance: $0.effect?.guidance) }
        guard review.canApply, review.plans.count == review.entries.count else {
            return notWritten(
                subjects, kind: .refused, detail: "Some changes cannot be applied. Look at them in the review.")
        }
        guard review.canApply(confirmed: confirmed) else {
            return notWritten(
                subjects, kind: .refused, detail: "Some changes need your confirmation. Tick each one in the review.")
        }
        let title = review.entries.count == 1 ? review.entries[0].title : "Apply \(review.entries.count) changes"
        return await execute(
            review.plans, subjects: subjects, title: title, intent: nil, pipeline: pipeline, home: home,
            replan: replan, date: date)
    }

    /// Apply could not start, for example because the backup folder cannot be opened; nothing was written.
    public static func cannotStart(_ review: Review, reason: String) -> ApplyOutcome {
        notWritten(
            review.entries.map { Subject(id: $0.id, title: $0.title, guidance: nil) }, kind: .refused, detail: reason)
    }

    /// One line of the result: what was asked, and when it takes effect once applied.
    struct Subject {
        let id: String
        let title: String
        let guidance: String?
    }

    /// Runs planned changes through the pipeline and says what happened to each subject.
    static func execute(
        _ plans: [PlannedChange], subjects: [Subject], title: String, intent: JSONValue?, pipeline: ApplyPipeline,
        home: String, replan: (@Sendable () throws -> [PlannedChange])? = nil, date: Date = Date(),
        appliedHeadline: String? = nil
    ) async -> ApplyOutcome {
        do {
            let result = try await pipeline.apply(plans, title: title, date: date, intent: intent, replan: replan)
            return outcome(subjects, result: result, home: home, appliedHeadline: appliedHeadline)
        } catch let error as StaleFileError {
            let file = ItemPresentation.abbreviate(error.file, home: home)
            return notWritten(
                subjects, kind: .stale, detail: "\(file) changed since the scan. Scan again, check the review, then apply.",
                staleFile: file)
        } catch let error as PlanError {
            return notWritten(subjects, kind: .refused, detail: error.reason)
        } catch {
            return notWritten(subjects, kind: .refused, detail: String(describing: error))
        }
    }

    private static func outcome(
        _ subjects: [Subject], result: ApplyResult, home: String, appliedHeadline: String?
    ) -> ApplyOutcome {
        let kind: Kind
        let state: Change.State
        switch result.status {
        case .applied: (kind, state) = (.applied, .applied)
        case .rolledBack: (kind, state) = (.rolledBack, .undone)
        case .failed, .inProgress: (kind, state) = (.failed, .undone)
        }
        let changes = subjects.map { subject in
            Change(
                id: subject.id, title: subject.title, state: state, guidance: state == .applied ? subject.guidance : nil)
        }
        let headline =
            kind == .applied ? appliedHeadline ?? headline(kind, count: changes.count) : headline(kind, count: changes.count)
        return ApplyOutcome(
            kind: kind, headline: headline, detail: result.failure, backupId: result.backupId, changes: changes,
            kept: result.kept.map { ItemPresentation.abbreviate($0, home: home) }, notes: result.notes, staleFile: nil)
    }

    static func notWritten(
        _ subjects: [Subject], kind: Kind, detail: String, staleFile: String? = nil
    ) -> ApplyOutcome {
        ApplyOutcome(
            kind: kind, headline: headline(kind, count: subjects.count), detail: detail, backupId: nil,
            changes: subjects.map { Change(id: $0.id, title: $0.title, state: .notWritten, guidance: nil) },
            kept: [], notes: [], staleFile: staleFile)
    }

    static func headline(_ kind: Kind, count: Int) -> String {
        switch kind {
        case .applied: count == 1 ? "Applied" : "Applied \(count) changes"
        case .rolledBack: "Applied, then rolled back"
        case .failed: "Applied, but the rollback did not finish"
        case .stale: "Nothing was written: a file changed since the scan"
        case .refused: "Nothing was written"
        }
    }
}

extension ApplyStep {
    /// What Apply is doing once it reached this step.
    public var label: String {
        switch self {
        case .backupStarted: "Backing up the files"
        case .originalsKept: "Moving removed items to the backup"
        case .moved: "Updating Claw's hook stash"
        case .stashed: "Writing the files"
        case .filesWritten: "Running claude"
        case .cliRan: "Checking the result"
        case .verified: "Finishing"
        }
    }

    /// How far Apply is, from 0 to 1, once it reached this step.
    public var fraction: Double {
        let all = Self.allCases
        return Double((all.firstIndex(of: self) ?? 0) + 1) / Double(all.count + 1)
    }
}

extension Review {
    /// The plans for the same queue, made again from the files as they are now. Throws when a change no longer plans.
    public static func plans(
        queue: ChangeQueue, items: [Item], planner: Planner, writeScope: WriteScope?, activeProject: String?,
        home: String
    ) throws -> [PlannedChange] {
        let again = make(
            queue: queue, items: items, planner: planner, writeScope: writeScope, activeProject: activeProject,
            home: home)
        guard again.canApply else {
            throw PlanError(reason: again.entries.compactMap(\.error).first ?? "Nothing to apply")
        }
        return again.plans
    }
}
