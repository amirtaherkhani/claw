import Foundation

/// What a finished scan does to the app's state. `AppModel` applies it; the rules live here so tests can cover them.
public struct ScanOutcome: Sendable {
    /// Whether the new result goes on screen. When false, the previous scan stays.
    public let replacesResult: Bool
    /// Only a complete scan can show that an item is gone, so a partial one leaves the queue alone. That covers
    /// Stop (later steps never ran) and a missing `claude` CLI (plugin-provided items are not listed). Even a
    /// complete scan speaks only for the places it covers (`covers`).
    public let queue: ChangeQueue
    /// What to tell the user, if anything.
    public let message: String?

    /// - Parameters:
    ///   - projects: the project folders the scan read. The items cannot say: a project whose last item was deleted
    ///     lists nothing, and that is the case that must prune.
    ///   - stopped: the user pressed Stop. `partial` cannot say so: it is also true without the CLI, and an empty
    ///     result then is a finding that must replace the old list. Empty after Stop only means "not looked at".
    public init(result: ScanResult, projects: [String], stopped: Bool, previous: ScanResult?, queue: ChangeQueue) {
        var kept = queue
        if !result.partial {
            let ids = Set(result.items.map(\.id))
            let read = Set(projects)
            for change in queue.changes
            where !ids.contains(change.itemId) && Self.covers(change, target: result.target, projects: read) {
                kept.discard(change)
            }
        }
        self.queue = kept

        // A Stop that lands after the last step leaves a complete result, which counts as a normal finish.
        let cutShort = stopped && result.partial
        let foundNothing = cutShort && result.items.isEmpty && previous != nil
        replacesResult = !foundNothing

        if foundNothing {
            message = "Scan stopped; showing the previous results"
        } else if cutShort {
            message = "Scan stopped; the results shown are partial"
        } else {
            message = result.partial ? "Scan finished with partial results" : nil
        }
    }

    /// Whether the scan looked where the change's item lives, so that its absence means the item is gone.
    /// A project item needs that project read; anything else needs a scan of this Mac. A folder scan lists nothing
    /// outside its folder, so it must never prune there: a wrongly dropped change is lost without a word.
    private static func covers(_ change: PendingChange, target: ScanTarget, projects: Set<String>) -> Bool {
        if let project = change.projectPath { return projects.contains(project) }
        return target.kind == .mac
    }
}
