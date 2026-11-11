import Foundation
import Testing

@testable import ClawCore

/// M4.6 (FR-F08-1 to 6, FR-F07-3): a change that deletes data or a sign-in, or touches a guard hook, carries a
/// risk the person must confirm before Apply; uninstalling keeps a plugin's data unless they choose otherwise; and a
/// Managed or organisation-required item is refused with a pointer to the administrator.
@Suite("Confirmations and warnings")
struct ConfirmationTests {
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: [])
    static let files: [String: String] = [
        "/h/.claude/settings.json":
            #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/bin/guard.sh"}]}]}}"#,
        "/h/.claude.json": #"{"mcpServers":{"remote":{"type":"http","url":"https://api.example.com/mcp"}}}"#,
    ]

    func setup() async -> (items: [Item], planner: Planner) {
        let fs = MemoryFileSystem(Self.files)
        let items = await ConfigScanner(environment: Self.env, fileSystem: fs, cli: nil).scan().items
        return (items, Planner(environment: Self.env, fileSystem: fs, commands: .standard))
    }

    static func plugin(_ ownership: Ownership = .market) -> Item {
        Item(
            concept: .plugins, key: "kit@m", name: "kit@m", description: "", scope: .user,
            classification: Classification(ownership: ownership, rule: "T", evidence: []), location: "/c",
            enabled: true, control: ControlRef(mechanism: .enabledPlugins, key: "enabledPlugins[\"kit@m\"]", status: .verified),
            capabilities: .forOwnership(ownership, isPlugin: true))
    }

    @Test("Uninstall keeps data by default; without Keep data it is a risk to confirm")
    func dataDeletion() throws {
        let planner = Planner(environment: Self.env, fileSystem: MemoryFileSystem([:]), commands: .standard)
        #expect(try planner.remove(Self.plugin()).risks.isEmpty)
        let deleting = try planner.remove(Self.plugin(), keepData: false)
        #expect(deleting.risks == [.deletesData])
        #expect(deleting.cli.first?.argv.contains("--keep-data") == false)
    }

    @Test("Removing a remote MCP server is a risk: its stored sign-in goes too")
    func signIn() async throws {
        let (items, planner) = await setup()
        let server = try #require(items.first { $0.concept == .mcp && $0.name == "remote" })
        let change = try planner.remove(server)
        #expect(change.risks == [.deletesSignIn])
        #expect(change.warnings.contains { $0.contains("sign-in") })
    }

    @Test("A guard hook is a risk when removed and when turned off, with a warning both ways")
    func guardHook() async throws {
        let (items, planner) = await setup()
        let hook = try #require(items.first { $0.concept == .hooks })
        let removed = try planner.remove(hook)
        #expect(removed.risks == [.guardHook])
        let off = try planner.setEnabled(hook, enabled: false, writeScope: nil, activeProject: nil)
        #expect(off.risks == [.guardHook])
        #expect(off.warnings.contains { $0.contains("Guard hook") })
    }

    @Test("Apply waits until every risky change is confirmed")
    func reviewConfirms() async throws {
        let (items, planner) = await setup()
        let server = try #require(items.first { $0.concept == .mcp && $0.name == "remote" })
        var queue = ChangeQueue()
        queue.toggleRemoval(server, home: "/h")
        let review = Review.make(
            queue: queue, items: items, planner: planner, writeScope: nil, activeProject: nil, home: "/h")
        let entry = try #require(review.entries.first)
        #expect(entry.risks == [.deletesSignIn])
        #expect(review.canApply)
        #expect(review.needsConfirmation == [entry.id])
        #expect(!review.canApply(confirmed: []))
        #expect(review.canApply(confirmed: [entry.id]))
        #expect(ChangeRisk.deletesSignIn.confirmation.contains("sign-in"))
    }

    @Test("The queue's Keep data choice reaches the plan")
    func keepDataInQueue() throws {
        let item = Self.plugin()
        var queue = ChangeQueue()
        queue.toggleRemoval(item, home: "/h")
        let change = try #require(queue.changes.first)
        #expect(change.keepData)
        queue.setKeepData(change, false)
        #expect(queue.changes.first?.keepData == false)
        let planner = Planner(environment: Self.env, fileSystem: MemoryFileSystem([:]), commands: .standard)
        let review = Review.make(
            queue: queue, items: [item], planner: planner, writeScope: nil, activeProject: nil, home: "/h")
        #expect(review.entries.first?.risks == [.deletesData])
        #expect(review.plans.first?.cli.first?.argv.contains("--keep-data") == false)
    }

    @Test("Managed and organisation-required items are refused, pointing to the administrator")
    func refusals() {
        #expect(Self.plugin(.managed).capabilities.reason?.contains("administrator") == true)
        let fs = MemoryFileSystem([
            "/managed/managed-settings.json": #"{"enabledPlugins":{"kit@m":true}}"#, "/h/.claude/settings.json": "{}",
        ])
        let planner = Planner(environment: Self.env, fileSystem: fs)
        let user = WriteScope(scope: .user, file: "/h/.claude/settings.json")
        #expect {
            try planner.setEnabled(Self.plugin(), enabled: false, writeScope: user, activeProject: nil)
        } throws: { error in
            (error as? PlanError)?.reason.contains("administrator") == true
        }
    }
}
