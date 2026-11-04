import Foundation
import Testing

@testable import ClawCore

@Suite("ConfigScanner")
struct ScannerTests {
    /// Fake HOME with one item of each plugin ownership and each skill location.
    static let files: [String: String] = [
        "/h/.claude/settings.json": """
        {"enabledPlugins":{"ecc@ecc":true,"nest@local-dev":true,"ghost@ecc":true},
         "skillOverrides":{"old-skill":"off"},"model":"opus"}
        """,
        "/p/.claude/settings.local.json": #"{"enabledPlugins":{"ecc@ecc":false}}"#,
        "/h/.claude/plugins/known_marketplaces.json": """
        {"ecc":{"source":{"source":"github","repo":"o/ecc"}},"local-dev":{"source":{"source":"directory","path":"/dev/m"}}}
        """,
        "/dev/m/.claude-plugin/marketplace.json": #"{"plugins":[{"name":"nest","source":"./plugins/nest"}]}"#,
        "/h/.claude/skills/my-skill/SKILL.md": "---\nname: my-skill\ndescription: Mine\n---\nbody",
        "/h/.claude/skills/old-skill/SKILL.md": "---\nname: old-skill\ndescription: Off\n---\n",
        "/h/.claude/skills/synced/team-skill/SKILL.md": "---\nname: team-skill\ndescription: From claude.ai\n---\n",
        "/p/.claude/skills/proj-skill/SKILL.md": "no frontmatter",
        "/c/ecc/skills/review/SKILL.md": "---\nname: review\ndescription: Plugin skill\n---\n",
    ]

    static let pluginList = """
        [{"id":"ecc@ecc","version":"1.0.0","scope":"user","enabled":true,"installPath":"/c/ecc"},
         {"id":"nest@local-dev","scope":"user","enabled":true,"installPath":"/c/nest"},
         {"id":"slack@synced","scope":"synced","enabled":true,"installPath":"/c/slack"},
         {"id":"lost@gone","scope":"user","enabled":true,"installPath":"/c/lost"}]
        """

    func scan(withCLI: Bool) async -> ScanResult {
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
        let cli =
            withCLI
            ? ClaudeCLI(
                executable: "/bin/claude",
                runner: FakeRunner(responses: [
                    "--version": ok("2.1.300 (Claude Code)\n"),
                    "plugin list --json": ok(Self.pluginList),
                ])) : nil
        return await ConfigScanner(environment: env, fileSystem: MemoryFileSystem(Self.files), cli: cli).scan()
    }

    func item(_ result: ScanResult, _ concept: Concept, _ name: String) throws -> Item {
        try #require(result.items.first { $0.concept == concept && $0.name == name }, "\(concept) \(name)")
    }

    @Test("Plugins: ownership, buckets, P8 and version")
    func plugins() async throws {
        let result = await scan(withCLI: true)
        #expect(!result.partial)
        #expect(result.claudeCodeVersion == "2.1.300 (Claude Code)")

        #expect(try item(result, .plugins, "ecc").bucket == .readonly)
        let nest = try item(result, .plugins, "nest")
        #expect(nest.bucket == .yours)
        #expect(nest.classification.rule == "P6")
        #expect(try item(result, .plugins, "slack").classification.ownership == .synced)
        #expect(try item(result, .plugins, "lost").bucket == .attention)

        let ghost = try item(result, .plugins, "ghost")
        #expect(ghost.classification.rule == "P8")
        #expect(ghost.bucket == .attention)
    }

    @Test("Skills: personal, override off, synced, project, plugin")
    func skills() async throws {
        let result = await scan(withCLI: true)
        let mine = try item(result, .skills, "my-skill")
        #expect(mine.bucket == .yours)
        #expect(mine.enabled)
        #expect(mine.capabilities.edit)

        let old = try item(result, .skills, "old-skill")
        #expect(!old.enabled)
        #expect(old.enabledBy == "user")

        #expect(try item(result, .skills, "team-skill").classification.ownership == .synced)

        let project = try item(result, .skills, "proj-skill")
        #expect(project.scope == .project)
        #expect(project.problems.contains { $0.message.contains("frontmatter") })

        let pluginSkill = try item(result, .skills, "ecc:review")
        #expect(pluginSkill.providedBy == "ecc@ecc")
        #expect(pluginSkill.control.mechanism == .parentPlugin)
        #expect(!pluginSkill.capabilities.toggle)
    }

    @Test("Without the CLI the scan is partial and plugins come from settings")
    func noCLI() async throws {
        let result = await scan(withCLI: false)
        #expect(result.partial)
        #expect(result.claudeCodeVersion == nil)
        let nest = try item(result, .plugins, "nest")
        #expect(nest.classification.rule == "P7")  // in-place loading cannot be proven without the CLI entry
        #expect(nest.bucket == .readonly)
        #expect(result.items.filter { $0.concept == .plugins }.count == 3)
    }

    @Test("JSON output never contains secrets from settings")
    func noSecrets() async throws {
        let result = await scan(withCLI: true)
        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!text.contains("fake-token"))
        #expect(text.contains("\"bucket\":\"yours\""))
    }
}

@Suite("Process runner")
struct ProcessRunnerTests {
    @Test("Runs without a shell and captures stdout")
    func echo() async throws {
        let result = try await ProcessRunner().run(executable: "/bin/echo", arguments: ["a; echo b"], timeoutSeconds: 5)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "a; echo b\n")
    }

    @Test("Times out and stops the program promptly")
    func timeout() async {
        let started = Date()
        await #expect(throws: CommandError.timedOut(seconds: 1)) {
            _ = try await ProcessRunner().run(executable: "/bin/sleep", arguments: ["10"], timeoutSeconds: 1)
        }
        #expect(Date().timeIntervalSince(started) < 4)
    }
}
