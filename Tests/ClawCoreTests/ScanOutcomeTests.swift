import Foundation
import Testing

@testable import ClawCore

@Suite("Finishing a scan")
struct ScanOutcomeTests {
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed")

    func skill(_ name: String) -> Item {
        Item(
            concept: .skills, key: name, name: name, description: "", scope: .user,
            classification: Classification(ownership: .personal, rule: "L1", evidence: []),
            location: "/h/.claude/skills/\(name)", enabled: true,
            control: ControlRef(mechanism: .skillOverrides, key: "skillOverrides[\"\(name)\"]", status: .verified),
            capabilities: Capabilities.forOwnership(.personal, isPlugin: false))
    }

    func result(_ items: [Item], partial: Bool = false) -> ScanResult {
        ScanResult(
            target: .mac, startedAt: Date(), finishedAt: Date(), partial: partial, claudeCodeVersion: nil, items: items,
            problems: [])
    }

    /// A queue with a change on each item.
    func queue(_ items: [Item]) -> ChangeQueue {
        var queue = ChangeQueue()
        let scope = WriteScope(scope: .user, file: "/h/.claude/settings.json")
        for item in items { queue.toggle(item, writeScope: scope, home: "/h") }
        return queue
    }

    // MARK: Queue

    @Test("A complete scan drops changes whose item is gone and keeps the rest")
    func completeScanPrunes() {
        let (kept, gone) = (skill("kept"), skill("gone"))
        let outcome = ScanOutcome(result: result([kept]), stopped: false, previous: nil, queue: queue([kept, gone]))
        #expect(outcome.queue.changes.map(\.itemId) == [kept.id])
    }

    @Test("A stopped scan keeps changes whose item it did not reach")
    func stoppedScanKeepsQueue() {
        let (reached, unreached) = (skill("reached"), skill("unreached"))
        let outcome = ScanOutcome(
            result: result([reached], partial: true), stopped: true, previous: nil, queue: queue([reached, unreached]))
        #expect(outcome.queue.changes.map(\.itemId) == [reached.id, unreached.id])
    }

    @Test("Stop during the settings step keeps the whole queue and the previous scan")
    func stopDuringSettings() async throws {
        let gate = ReadGate()
        defer { gate.release() }
        let fs = BlockingFileSystem(blocked: "/h/.claude/settings.json", gate: gate)
        let scanner = ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil)

        // `AppModel` reads `Task.isCancelled` the same way: in the scan's task, after the scan returns.
        let task = Task {
            let scan = await scanner.scan()
            return (scan: scan, stopped: Task.isCancelled)
        }
        try await gate.waitUntilHolding()
        task.cancel()
        let finished = try #require(await value(of: task, within: 1))
        #expect(finished.scan.items.isEmpty)
        #expect(finished.stopped)

        let (first, second) = (skill("first"), skill("second"))
        let outcome = ScanOutcome(
            result: finished.scan, stopped: finished.stopped, previous: result([first, second]), queue: queue([first, second]))
        #expect(outcome.queue.count == 2)
        #expect(!outcome.replacesResult)
    }

    /// Without the CLI, plugins not named in settings and everything plugins provide are missing, so absence proves nothing.
    @Test("A scan without the claude CLI keeps changes on plugin items it cannot see")
    func missingCLIKeepsQueue() async {
        let fs = MemoryFileSystem(["/h/.claude/skills/a/SKILL.md": "---\nname: a\n---\n"])
        let scan = await ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil).scan()
        #expect(scan.partial)

        let outcome = ScanOutcome(result: scan, stopped: false, previous: nil, queue: queue([skill("from-a-plugin")]))
        #expect(outcome.queue.count == 1)
    }

    @Test("Stop pressed after the last step changes nothing: the scan is complete and still prunes")
    func stopAfterLastStep() {
        let gone = skill("gone")
        let outcome = ScanOutcome(result: result([]), stopped: true, previous: result([gone]), queue: queue([gone]))
        #expect(outcome.queue.isEmpty)
        #expect(outcome.replacesResult)
        #expect(outcome.message == nil)
    }

    // MARK: Result on screen

    @Test("A stopped scan that found items replaces the list, labelled partial (FR-F02-3)")
    func stoppedWithItemsReplaces() {
        let outcome = ScanOutcome(
            result: result([skill("a")], partial: true), stopped: true, previous: result([skill("a"), skill("b")]),
            queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == "Scan stopped; the results shown are partial")
    }

    @Test("A stopped scan that found nothing leaves the previous scan on screen and says so")
    func stoppedEmptyKeepsPrevious() {
        let outcome = ScanOutcome(
            result: result([], partial: true), stopped: true, previous: result([skill("a")]), queue: ChangeQueue())
        #expect(!outcome.replacesResult)
        #expect(outcome.message == "Scan stopped; showing the previous results")
    }

    @Test("The first scan shows its result even when stopped with nothing found")
    func stoppedEmptyWithoutPrevious() {
        let outcome = ScanOutcome(result: result([], partial: true), stopped: true, previous: nil, queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == "Scan stopped; the results shown are partial")
    }

    /// An empty result here is a finding: the files are gone. Only Stop makes an empty result mean "not looked at".
    @Test("An empty partial scan that was not stopped replaces the previous scan")
    func emptyWithoutCLIReplaces() {
        let outcome = ScanOutcome(
            result: result([], partial: true), stopped: false, previous: result([skill("a")]), queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == "Scan finished with partial results")
    }

    @Test("A complete scan replaces the previous scan without a message")
    func completeReplaces() {
        let outcome = ScanOutcome(result: result([]), stopped: false, previous: result([skill("a")]), queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == nil)
    }
}
