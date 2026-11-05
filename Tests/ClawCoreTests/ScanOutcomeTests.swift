import Foundation
import Testing

@testable import ClawCore

@Suite("Finishing a scan")
struct ScanOutcomeTests {
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed")

    /// A user-level skill, or a project skill when `project` is set.
    func skill(_ name: String, project: String? = nil) -> Item {
        Item(
            concept: .skills, key: project.map { "\($0):\(name)" } ?? name, name: name, description: "",
            scope: project == nil ? .user : .project, projectPath: project,
            classification: Classification(ownership: .personal, rule: project == nil ? "L1" : "L2", evidence: []),
            location: "\(project ?? "/h")/.claude/skills/\(name)", enabled: true,
            control: ControlRef(mechanism: .skillOverrides, key: "skillOverrides[\"\(name)\"]", status: .verified),
            capabilities: Capabilities.forOwnership(.personal, isPlugin: false))
    }

    func result(_ items: [Item], partial: Bool = false, target: ScanTarget = .mac) -> ScanResult {
        ScanResult(
            target: target, startedAt: Date(), finishedAt: Date(), partial: partial, claudeCodeVersion: nil, items: items,
            problems: [])
    }

    /// A real scan that ran every step, so `partial` is false.
    func completeScan(_ target: ScanTarget, projects: [String], files: [String: String]) async -> ScanResult {
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: projects)
        let cli = ClaudeCLI(
            executable: "/bin/claude",
            runner: FakeRunner(responses: ["--version": ok("2.1.317 (Claude Code)"), "plugin list --json": ok("[]")]))
        return await ConfigScanner(environment: env, target: target, fileSystem: MemoryFileSystem(files), cli: cli).scan()
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
        let outcome = ScanOutcome(
            result: result([kept]), projects: [], stopped: false, previous: nil, queue: queue([kept, gone]))
        #expect(outcome.queue.changes.map(\.itemId) == [kept.id])
    }

    @Test("A stopped scan keeps changes whose item it did not reach")
    func stoppedScanKeepsQueue() {
        let (reached, unreached) = (skill("reached"), skill("unreached"))
        let outcome = ScanOutcome(
            result: result([reached], partial: true), projects: [], stopped: true, previous: nil,
            queue: queue([reached, unreached]))
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
            result: finished.scan, projects: [], stopped: finished.stopped, previous: result([first, second]),
            queue: queue([first, second]))
        #expect(outcome.queue.count == 2)
        #expect(!outcome.replacesResult)
    }

    /// Without the CLI, plugins not named in settings and everything plugins provide are missing, so absence proves nothing.
    @Test("A scan without the claude CLI keeps changes on plugin items it cannot see")
    func missingCLIKeepsQueue() async {
        let fs = MemoryFileSystem(["/h/.claude/skills/a/SKILL.md": "---\nname: a\n---\n"])
        let scan = await ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil).scan()
        #expect(scan.partial)

        let outcome = ScanOutcome(
            result: scan, projects: [], stopped: false, previous: nil, queue: queue([skill("from-a-plugin")]))
        #expect(outcome.queue.count == 1)
    }

    @Test("Stop pressed after the last step changes nothing: the scan is complete and still prunes")
    func stopAfterLastStep() {
        let gone = skill("gone")
        let outcome = ScanOutcome(result: result([]), projects: [], stopped: true, previous: result([gone]), queue: queue([gone]))
        #expect(outcome.queue.isEmpty)
        #expect(outcome.replacesResult)
        #expect(outcome.message == nil)
    }

    // MARK: What the scan covers

    @Test("A folder scan keeps changes on user-level items, which it does not list")
    func folderScanKeepsUserChanges() {
        let (here, user) = (skill("here", project: "/p"), skill("user"))
        let outcome = ScanOutcome(
            result: result([here], target: .folder("/p")), projects: ["/p"], stopped: false, previous: nil,
            queue: queue([here, user]))
        #expect(outcome.queue.changes.map(\.itemId) == [here.id, user.id])
    }

    @Test("A folder scan keeps changes on items in other projects")
    func folderScanKeepsOtherProjects() {
        let other = skill("other", project: "/other")
        let outcome = ScanOutcome(
            result: result([], target: .folder("/p")), projects: ["/p"], stopped: false, previous: nil, queue: queue([other]))
        #expect(outcome.queue.changes.map(\.itemId) == [other.id])
    }

    @Test("A folder scan drops changes whose item is gone from that folder")
    func folderScanPrunesItsFolder() {
        let gone = skill("gone", project: "/p")
        let outcome = ScanOutcome(
            result: result([], target: .folder("/p")), projects: ["/p"], stopped: false, previous: nil, queue: queue([gone]))
        #expect(outcome.queue.isEmpty)
    }

    @Test("A Mac scan drops changes whose item is gone from a project it read")
    func macScanPrunesKnownProject() {
        let gone = skill("gone", project: "/p")
        let outcome = ScanOutcome(result: result([]), projects: ["/p"], stopped: false, previous: nil, queue: queue([gone]))
        #expect(outcome.queue.isEmpty)
    }

    @Test("A Mac scan keeps changes on items from a folder it did not read")
    func macScanKeepsUnknownFolder() {
        let elsewhere = skill("elsewhere", project: "/elsewhere")
        let outcome = ScanOutcome(result: result([]), projects: ["/p"], stopped: false, previous: nil, queue: queue([elsewhere]))
        #expect(outcome.queue.changes.map(\.itemId) == [elsewhere.id])
    }

    @Test("A real folder scan keeps the user-level change and drops the one on a deleted project skill")
    func realFolderScan() async throws {
        let (userFile, projectFile) = ("/h/.claude/skills/mine/SKILL.md", "/p/.claude/skills/shared/SKILL.md")
        let (front, projects) = ("---\ndescription: d\n---\n", ["/p"])
        let mac = await completeScan(.mac, projects: projects, files: [userFile: front, projectFile: front])
        let user = try #require(mac.items.first { $0.name == "mine" })
        let project = try #require(mac.items.first { $0.name == "shared" })

        let folder = await completeScan(.folder("/p"), projects: projects, files: [userFile: front])
        #expect(!folder.partial)
        #expect(folder.items.isEmpty)

        let outcome = ScanOutcome(
            result: folder, projects: projects, stopped: false, previous: mac, queue: queue([user, project]))
        #expect(outcome.queue.changes.map(\.itemId) == [user.id])
    }

    @Test("A real Mac scan keeps a change from a folder scan until it reads that folder")
    func realMacScan() async throws {
        let file = "/elsewhere/.claude/skills/shared/SKILL.md"
        let folder = await completeScan(
            .folder("/elsewhere"), projects: ["/elsewhere"], files: [file: "---\ndescription: d\n---\n"])
        let item = try #require(folder.items.first)

        let unknown = await completeScan(.mac, projects: [], files: [:])
        #expect(!unknown.partial)
        let kept = ScanOutcome(result: unknown, projects: [], stopped: false, previous: folder, queue: queue([item]))
        #expect(kept.queue.count == 1)

        let known = await completeScan(.mac, projects: ["/elsewhere"], files: [:])
        let pruned = ScanOutcome(
            result: known, projects: ["/elsewhere"], stopped: false, previous: folder, queue: queue([item]))
        #expect(pruned.queue.isEmpty)
    }

    /// Its record has no project, so only the settings layer that declares it can say where it lives.
    @Test("A plugin declared only in a project's settings belongs to that project")
    func declaredPluginBelongsToProject() async throws {
        let settings = ["/p/.claude/settings.json": #"{"enabledPlugins":{"ghost@gone":true}}"#]
        let folder = await completeScan(.folder("/p"), projects: ["/p"], files: settings)
        let ghost = try #require(folder.items.first { $0.name == "ghost" })
        #expect(ghost.id == "plugins:user:ghost@gone")
        #expect(ghost.projectPath == "/p")

        var queued = ChangeQueue()
        #expect(queued.toggleRemoval(ghost, home: "/h") == nil)

        let unknown = await completeScan(.mac, projects: [], files: [:])
        let kept = ScanOutcome(result: unknown, projects: [], stopped: false, previous: folder, queue: queued)
        #expect(kept.queue.count == 1)

        let known = await completeScan(.mac, projects: ["/p"], files: [:])
        let pruned = ScanOutcome(result: known, projects: ["/p"], stopped: false, previous: folder, queue: queued)
        #expect(pruned.queue.isEmpty)
    }

    // MARK: Result on screen

    @Test("A stopped scan that found items replaces the list, labelled partial (FR-F02-3)")
    func stoppedWithItemsReplaces() {
        let outcome = ScanOutcome(
            result: result([skill("a")], partial: true), projects: [], stopped: true, previous: result([skill("a"), skill("b")]),
            queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == "Scan stopped; the results shown are partial")
    }

    @Test("A stopped scan that found nothing leaves the previous scan on screen and says so")
    func stoppedEmptyKeepsPrevious() {
        let outcome = ScanOutcome(
            result: result([], partial: true), projects: [], stopped: true, previous: result([skill("a")]), queue: ChangeQueue())
        #expect(!outcome.replacesResult)
        #expect(outcome.message == "Scan stopped; showing the previous results")
    }

    @Test("The first scan shows its result even when stopped with nothing found")
    func stoppedEmptyWithoutPrevious() {
        let outcome = ScanOutcome(
            result: result([], partial: true), projects: [], stopped: true, previous: nil, queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == "Scan stopped; the results shown are partial")
    }

    /// An empty result here is a finding: the files are gone. Only Stop makes an empty result mean "not looked at".
    @Test("An empty partial scan that was not stopped replaces the previous scan")
    func emptyWithoutCLIReplaces() {
        let outcome = ScanOutcome(
            result: result([], partial: true), projects: [], stopped: false, previous: result([skill("a")]), queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == "Scan finished with partial results")
    }

    @Test("A complete scan replaces the previous scan without a message")
    func completeReplaces() {
        let outcome = ScanOutcome(
            result: result([]), projects: [], stopped: false, previous: result([skill("a")]), queue: ChangeQueue())
        #expect(outcome.replacesResult)
        #expect(outcome.message == nil)
    }
}
