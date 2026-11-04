import Foundation

/// What a finished scan does to the app's state. `AppModel` applies it; the rules live here so tests can cover them.
public struct ScanOutcome: Sendable {
    /// Whether the new result goes on screen. When false, the previous scan stays.
    public let replacesResult: Bool
    /// Only a complete scan can show that an item is gone, so a partial one leaves the queue alone. That covers
    /// Stop (later steps never ran) and a missing `claude` CLI (plugin-provided items are not listed).
    public let queue: ChangeQueue
    /// What to tell the user, if anything.
    public let message: String?

    /// - Parameter stopped: the user pressed Stop. `partial` cannot say so: it is also true without the CLI, and an
    ///   empty result then is a finding that must replace the old list. Empty after Stop only means "not looked at".
    public init(result: ScanResult, stopped: Bool, previous: ScanResult?, queue: ChangeQueue) {
        var kept = queue
        if !result.partial {
            let ids = Set(result.items.map(\.id))
            for change in queue.changes where !ids.contains(change.itemId) { kept.discard(change) }
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
}
