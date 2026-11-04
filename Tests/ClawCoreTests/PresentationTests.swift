import Foundation
import Testing

@testable import ClawCore

@Suite("Presentation")
struct PresentationTests {
    /// Reuses the concept fixture so items come from a real scan.
    func items() async -> [Item] {
        await ConceptTests().scan(extra: [
            "/h/.claude/plugins/known_marketplaces.json": #"{"m":{"source":{"source":"github","repo":"o/m"}}}"#
        ]).items
    }

    func item(_ items: [Item], _ concept: Concept, _ name: String) throws -> Item {
        try #require(items.first { $0.concept == concept && $0.name == name })
    }

    @Test("Toggle queues a change, toggling again removes it; read-only items refuse")
    func queueToggle() async throws {
        let all = await items()
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
        let scope = WriteScope.resolve(.user, environment: env, activeProject: nil)
        var queue = ChangeQueue()

        let plugin = try item(all, .plugins, "kit")
        #expect(queue.toggle(plugin, writeScope: scope, home: "/h") == nil)
        #expect(queue.count == 1)
        #expect(!queue.effectiveEnabled(plugin))
        let change = try #require(queue.pending(for: plugin.id))
        #expect(change.title == "Disable kit")
        #expect(change.target == "~/.claude/settings.json")
        #expect(change.preview.map(\.kind) == [.context, .removed, .added])
        #expect(change.preview[2].text.contains("\"kit@m\": false"))
        #expect(change.notes.contains { $0.contains("/reload-plugins") })

        queue.toggle(plugin, writeScope: scope, home: "/h")
        #expect(queue.isEmpty)

        let pluginCommand = try item(all, .commands, "/kit:build")
        #expect(queue.toggle(pluginCommand, writeScope: scope, home: "/h") != nil)
        #expect(queue.isEmpty)
    }

    @Test("Previews per mechanism, removal, unverified note")
    func previews() async throws {
        let all = await items()
        var queue = ChangeQueue()
        let scope = WriteScope(scope: .user, file: "/h/.claude/settings.json")

        queue.toggle(try item(all, .agents, "code-reviewer"), writeScope: scope, home: "/h")
        queue.toggle(try item(all, .rules, "CLAUDE.md"), writeScope: scope, home: "/h")
        queue.toggle(try item(all, .hooks, "PreToolUse [Bash] · guard.sh"), writeScope: scope, home: "/h")
        queue.toggle(try item(all, .commands, "/deploy"), writeScope: scope, home: "/h")
        queue.toggleRemoval(try item(all, .commands, "/test"), home: "/h")

        let texts = queue.changes.map { $0.preview.map(\.text).joined(separator: "\n") }
        #expect(texts[0].contains("Agent(code-reviewer)"))
        #expect(texts[1].contains("/p/CLAUDE.md"))
        #expect(texts[2].contains("stash"))
        #expect(texts[3].contains("\"deploy\": \"off\""))
        #expect(queue.changes[3].notes.contains { $0.contains("not verified") })
        #expect(queue.changes[4].action == .remove)
        #expect(queue.changes[4].target == "/p/.claude/commands/test.md")
        #expect(texts[4].contains("never hard-deleted"))

        let managedRule = try item(all, .rules, "/managed/CLAUDE.md")
        #expect(queue.toggleRemoval(managedRule, home: "/h") != nil)
    }

    @Test("Write scope needs an active project for Project and Local")
    func writeScope() {
        let env = ClaudeEnvironment(home: "/h", managedDir: "/m")
        #expect(WriteScope.resolve(.project, environment: env, activeProject: nil) == nil)
        #expect(WriteScope.resolve(.local, environment: env, activeProject: "/p")?.file == "/p/.claude/settings.local.json")
        #expect(WriteScope.resolve(.user, environment: env, activeProject: nil)?.file == "/h/.claude/settings.json")
    }

    @Test("Overview stats and headline come from the scan")
    func stats() async {
        let all = await items()
        let stats = OverviewStats(items: all, problems: 0)
        #expect(stats.total == all.count)
        #expect(stats.enabled == all.filter(\.enabled).count)
        #expect(stats.byBucket.values.reduce(0, +) == stats.total)
        #expect(stats.headline(pending: 0).contains("attention") == (stats.attention > 0))
        #expect(OverviewStats(items: [], problems: 0).headline(pending: 0).contains("Run a scan"))
    }

    @Test("Source flows: origins and concepts link to buckets with matching weights")
    func flows() async {
        let all = await items()
        let mcp = all.filter { $0.concept == .mcp }
        let sources = SourceFlow.sources(of: mcp)
        #expect(sources.left.map(\.id).contains("files"))
        #expect(sources.links.map(\.weight).reduce(0, +) == mcp.count)
        let concepts = SourceFlow.concepts(of: all)
        #expect(concepts.left.count == Concept.allCases.count)
        #expect(concepts.right.map(\.bucket) == Bucket.allCases)
        #expect(concepts.links.map(\.weight).reduce(0, +) == all.count)
    }

    @Test("Seeded particles are deterministic and show the enabled share")
    func particles() {
        let a = RingParticle.ring(count: 120, enabledFraction: 0.25)
        #expect(a == RingParticle.ring(count: 120, enabledFraction: 0.25))
        #expect(a.filter(\.lit).count == 30)
        #expect(a.allSatisfy { $0.radius >= 0.86 && $0.radius <= 1 })
    }

    @Test("Project inspection lists what a folder holds")
    func projectInspection() {
        let fs = MemoryFileSystem(ConceptTests.files)
        let p = ProjectInspection.inspect("/p", fileSystem: fs)
        #expect(p.isProject)
        #expect(p.rows.first { $0.path == ".mcp.json" }?.found == true)
        #expect(p.rows.first { $0.path == ".claude/commands/" }?.label == "1 commands")
        #expect(!ProjectInspection.inspect("/empty", fileSystem: fs).isProject)
    }

    @Test("Plugin source inspection predicts ownership")
    func pluginSource() {
        let fs = MemoryFileSystem([
            "/dev/m/.claude-plugin/marketplace.json": """
            {"name":"local-dev","plugins":[{"name":"nest","source":"./plugins/nest","description":"NestJS kit"},
             {"name":"far","source":{"source":"github","repo":"o/far"}},{"name":"bad name"}]}
            """
        ])
        let local = PluginSourceInspection.localFolder("/dev/m", fileSystem: fs)
        #expect(local.outcome == .personal)
        #expect(local.entries.map(\.name) == ["nest", "far"])
        #expect(
            local.commands(pluginName: "nest", scope: .user, input: "/dev/m") == [
                "claude plugin marketplace add /dev/m", "claude plugin install nest@local-dev --scope user",
            ])
        #expect(!PluginSourceInspection.localFolder("/nothing", fileSystem: fs).problems.isEmpty)
        #expect(PluginSourceInspection.github("owner/repo").problems.isEmpty)
        #expect(!PluginSourceInspection.github("owner/repo; rm").problems.isEmpty)
        #expect(PluginSourceInspection.github("o/r").outcome == .market)
    }

    @Test("Item text helpers")
    func text() async throws {
        let all = await items()
        #expect(ItemPresentation.monogram("/git:commit") == "GC")
        #expect(ItemPresentation.monogram("code-reviewer") == "CR")
        #expect(ItemPresentation.abbreviate("/h/.claude/x", home: "/h") == "~/.claude/x")
        #expect(ItemPresentation.abbreviate("/hx/y", home: "/h") == "/hx/y")
        #expect(ItemPresentation.kind(try item(all, .mcp, "github")) == "http")
        let hook = try item(all, .hooks, "PreToolUse [Bash] · guard.sh")
        #expect(ItemPresentation.file(hook) == "/h/.claude/settings.json")
        #expect(ItemPresentation.meta(hook, home: "/h").contains { $0.key == "Why" })
    }
}
