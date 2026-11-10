import Foundation
import Testing

@testable import ClawCore

/// M4.2: the Review sheet shows what Apply would really write. Each queued change is planned on top of the ones
/// before it, its diff masks secrets, hook arguments are never shown, and the backup folder and checklist come
/// from the plan. Planning reads only; nothing is written.
@Suite("Review of queued changes")
struct ReviewTests {
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: [])
    static let files: [String: String] = [
        "/h/.claude/settings.json":
            #"{"theme":"dark","hooks":{"Stop":[{"hooks":["#
            + #"{"type":"command","command":"/bin/s.sh --token fake-secret-9"},"#
            + #"{"type":"command","command":"/bin/echo done"}]}]}}"#,
        "/h/.claude.json": #"{"mcpServers":{"notes":{"command":"/bin/cat","env":{"TOKEN":"fake-secret-4"}}}}"#,
        "/h/.claude/skills/tidy/SKILL.md": "---\nname: tidy\ndescription: Tidy\n---\nB\n",
    ]

    func setup() async -> (items: [Item], planner: Planner) {
        let fs = MemoryFileSystem(Self.files)
        let result = await ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil).scan()
        return (result.items, Planner(environment: Self.env, fileSystem: fs))
    }

    func item(_ items: [Item], _ concept: Concept, _ name: String) throws -> Item {
        try #require(items.first { $0.concept == concept && $0.name.hasSuffix(name) })
    }

    func review(_ queue: ChangeQueue, _ items: [Item], _ planner: Planner, project: String? = "/p") -> Review {
        Review.make(queue: queue, items: items, planner: planner, writeScope: nil, activeProject: project, home: "/h")
    }

    @Test("Each change shows its real file diff, by file, with the home folder shortened")
    func realDiff() async throws {
        let (items, planner) = await setup()
        var queue = ChangeQueue()
        queue.toggle(try item(items, .mcp, "notes"), writeScope: nil, home: "/h")
        let review = review(queue, items, planner)
        let entry = try #require(review.entries.first)
        #expect(entry.error == nil)
        #expect(entry.files.map(\.path) == ["~/.claude.json"])
        let lines = try #require(entry.files.first).lines
        #expect(lines.contains { $0.kind == .added && $0.text.contains("disabledMcpServers") })
        #expect(review.plans.count == 1)
        #expect(review.canApply)
        let noProject = self.review(queue, items, planner, project: nil)
        #expect(noProject.entries.first?.error?.contains("Choose the project") == true)
        #expect(!noProject.canApply)
    }

    @Test("Secrets are masked, and a hook shows its script, never its arguments")
    func masked() async throws {
        let (items, planner) = await setup()
        var queue = ChangeQueue()
        queue.toggle(try item(items, .mcp, "notes"), writeScope: nil, home: "/h")
        queue.toggle(try item(items, .hooks, "s.sh"), writeScope: nil, home: "/h")
        let text = review(queue, items, planner).entries
            .flatMap { $0.files.flatMap(\.lines).map(\.text) + $0.notes + [$0.stash ?? ""] }
            .joined(separator: "\n")
        #expect(!text.contains("fake-secret"))
        #expect(text.contains("/bin/s.sh"))
    }

    @Test("Two hooks of one group turned off together: planned last-first, each builds on the other")
    func sameGroup() async throws {
        let (items, planner) = await setup()
        var queue = ChangeQueue()
        queue.toggle(try item(items, .hooks, "s.sh"), writeScope: nil, home: "/h")
        queue.toggle(try item(items, .hooks, "echo"), writeScope: nil, home: "/h")
        let review = review(queue, items, planner)
        #expect(review.entries.allSatisfy { $0.error == nil })
        #expect(review.entries.map(\.title) == queue.changes.map(\.title), "entries stay in the queue's order")
        #expect(review.entries.allSatisfy { $0.stash != nil })
        let edits = review.plans.flatMap(\.edits)
        #expect(edits.count == 2)
        let original = Data(try #require(Self.files["/h/.claude/settings.json"]).utf8)
        let first = try #require(edits.first { $0.before == original }, "one plan starts from the file on disk")
        let second = try #require(edits.first { $0.before == first.after }, "the other starts from its result")
        let final = try JSONValue.parse(second.after)
        #expect(final["hooks"] == nil)
        #expect(final["theme"]?.stringValue == "dark")
    }

    @Test("A removal moves the folder to the backup; the checklist names the backup folder")
    func removal() async throws {
        let (items, planner) = await setup()
        var queue = ChangeQueue()
        queue.toggleRemoval(try item(items, .skills, "tidy"), home: "/h")
        let review = review(queue, items, planner)
        let entry = try #require(review.entries.first)
        #expect(entry.moves == ["~/.claude/skills/tidy"])
        #expect(review.backupFolder == "~/.claude.bak/‹time›/")
        #expect(review.checklist.first?.contains("~/.claude.bak/") == true)
        #expect(!review.needsReloadPlugins)
    }

    @Test("A change whose item is gone cannot be applied, and says why")
    func gone() async throws {
        let (items, planner) = await setup()
        var queue = ChangeQueue()
        queue.toggle(try item(items, .skills, "tidy"), writeScope: nil, home: "/h")
        let review = review(queue, items.filter { $0.concept != .skills }, planner)
        #expect(review.entries.first?.error != nil)
        #expect(review.plans.isEmpty)
        #expect(!review.canApply)
    }

    @Test("An empty queue gives an empty review that cannot be applied")
    func empty() async throws {
        let (items, planner) = await setup()
        let review = review(ChangeQueue(), items, planner)
        #expect(review.entries.isEmpty)
        #expect(!review.canApply)
    }
}
