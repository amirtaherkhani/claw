import Foundation
import Testing

@testable import ClawCore

@Suite("Commands, subagents, rules, MCP servers, hooks")
struct ConceptTests {
    static let files: [String: String] = [
        "/h/.claude/settings.json": """
        {"enabledPlugins":{"kit@m":true},
         "skillOverrides":{"old-cmd":"off"},
         "permissions":{"deny":["Agent(blocked-agent)"]},
         "claudeMdExcludes":["/p/.claude/rules/**"],
         "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"API_KEY=fake-secret-1 /usr/local/bin/guard.sh --token fake-secret-2"}]}],
                  "Stop":[{"hooks":[{"type":"prompt","prompt":"x"}]}]}}
        """,
        "/p/.claude/settings.json": """
        {"enabledMcpjsonServers":["db"],"disabledMcpjsonServers":["off-server"],"disableAllHooks":false}
        """,
        "/p/.claude/settings.local.json":
            #"{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"npx fmt"}]}]}}"#,
        "/h/.claude/commands/deploy.md": "---\ndescription: Deploy it\n---\nbody",
        "/h/.claude/commands/old-cmd.md": "# Old command\nbody",
        "/h/.claude/commands/git/commit.md": "Commit staged changes",
        "/p/.claude/commands/test.md": "Run tests",
        "/h/.claude/agents/reviewer.md": "---\nname: code-reviewer\ndescription: Reviews code\n---\n",
        "/h/.claude/agents/blocked.md": "---\nname: blocked-agent\ndescription: Denied\n---\n",
        "/h/.claude/agents/broken.md": "no frontmatter",
        "/h/.claude/CLAUDE.md": "# Mine",
        "/h/.claude/rules/style.md": "Use tabs",
        "/p/CLAUDE.md": "# Project",
        "/p/CLAUDE.local.md": "# Local",
        "/p/.claude/rules/security.md": "Rule",
        "/managed/CLAUDE.md": "# Policy",
        "/h/.claude.json": """
        {"mcpServers":{"github":{"type":"http","url":"https://api.example.com/mcp?token=fake-secret-3","headers":{"Authorization":"Bearer fake-secret-4"}}},
         "projects":{"/p":{"mcpServers":{"local-tool":{"command":"/opt/bin/tool","args":["--key","fake-secret-5"],"env":{"K":"fake-secret-6"}}},
                           "disabledMcpServers":["github"]}},
         "oauthAccount":{"emailAddress":"someone@example.com"}}
        """,
        "/p/.mcp.json":
            #"{"mcpServers":{"db":{"command":"npx","args":["db-mcp"]},"off-server":{"command":"x"},"new-one":{"url":"https://new.example.com"}}}"#,
        "/c/kit/commands/build.md": "Build",
        "/c/kit/agents/helper.md": "---\nname: helper\ndescription: Helps\n---\n",
        "/c/kit/.mcp.json": #"{"mcpServers":{"search":{"command":"node","args":["s.js"]}}}"#,
        "/c/kit/hooks/hooks.json":
            #"{"description":"x","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/start.sh"}]}]}}"#,
    ]

    func scan(extra: [String: String] = [:]) async -> ScanResult {
        let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
        let cli = ClaudeCLI(
            executable: "/bin/claude",
            runner: FakeRunner(responses: [
                "--version": ok("2.1.317 (Claude Code)"),
                "plugin list --json": ok(#"[{"id":"kit@m","scope":"user","enabled":true,"installPath":"/c/kit"}]"#),
            ]))
        let fs = MemoryFileSystem(Self.files.merging(extra) { $1 })
        return await ConfigScanner(environment: env, fileSystem: fs, cli: cli).scan()
    }

    func item(_ result: ScanResult, _ concept: Concept, _ name: String) throws -> Item {
        try #require(result.items.first { $0.concept == concept && $0.name == name }, "\(concept) \(name)")
    }

    @Test("Commands: path names, nested namespace, override off, plugin commands")
    func commands() async throws {
        let result = await scan()
        #expect(try item(result, .commands, "/deploy").description == "Deploy it")
        #expect(try item(result, .commands, "/git:commit").bucket == .yours)
        #expect(try !item(result, .commands, "/old-cmd").enabled)
        #expect(try item(result, .commands, "/old-cmd").control.status == .unknown)
        #expect(try item(result, .commands, "/test").scope == .project)
        #expect(try item(result, .commands, "/kit:build").providedBy == "kit@m")
    }

    @Test("Subagents: frontmatter name, deny rule, missing description, plugin agents")
    func agents() async throws {
        let result = await scan()
        #expect(try item(result, .agents, "code-reviewer").enabled)
        let blocked = try item(result, .agents, "blocked-agent")
        #expect(!blocked.enabled)
        #expect(blocked.enabledBy == "permissions.deny")
        #expect(try item(result, .agents, "broken").problems.contains { $0.message.contains("description") })
        #expect(try item(result, .agents, "kit:helper").bucket == .readonly)
    }

    @Test("Rules: all locations, claudeMdExcludes glob, managed cannot be excluded")
    func rules() async throws {
        let result = await scan()
        let names = Set(result.items.filter { $0.concept == .rules }.map(\.name))
        #expect(
            names == [
                "~/.claude/CLAUDE.md", "~/.claude/rules/style.md", "CLAUDE.md", "CLAUDE.local.md", ".claude/rules/security.md",
                "/managed/CLAUDE.md",
            ])
        #expect(try !item(result, .rules, ".claude/rules/security.md").enabled)
        #expect(try item(result, .rules, "CLAUDE.local.md").scope == .local)
        let managed = try item(result, .rules, "/managed/CLAUDE.md")
        #expect(managed.bucket == .readonly)
        #expect(managed.enabled)
        #expect(!managed.capabilities.toggle)
    }

    @Test("MCP: scopes, approval, per-project disable, plugin naming, no secrets")
    func mcp() async throws {
        let result = await scan()
        let github = try item(result, .mcp, "github")
        #expect(github.description == "http · api.example.com")
        #expect(github.problems.contains { $0.message.contains("/p") })
        #expect(try item(result, .mcp, "local-tool").description == "stdio · tool")
        #expect(try item(result, .mcp, "db").enabled)
        #expect(try !item(result, .mcp, "off-server").enabled)
        let pending = try item(result, .mcp, "new-one")
        #expect(!pending.enabled)
        #expect(pending.problems.contains { $0.message.contains("approved") })
        #expect(try item(result, .mcp, "plugin:kit:search").providedBy == "kit@m")

        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        for secret in ["fake-secret-3", "fake-secret-4", "fake-secret-5", "fake-secret-6", "someone@example.com"] {
            #expect(!json.contains(secret), "leaked \(secret)")
        }
    }

    @Test("Hooks: one item per handler, guard flag, no command arguments or env values")
    func hooks() async throws {
        let result = await scan()
        let hooks = result.items.filter { $0.concept == .hooks }
        #expect(hooks.count == 4)
        let guardHook = try item(result, .hooks, "PreToolUse [Bash] · guard.sh")
        #expect(guardHook.problems.contains { $0.message.contains("Guard") })
        #expect(guardHook.control.mechanism == .hookStash)
        #expect(try item(result, .hooks, "PostToolUse · npx").scope == .local)
        #expect(try item(result, .hooks, "SessionStart · start.sh").providedBy == "kit@m")

        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(!json.contains("fake-secret-1"))
        #expect(!json.contains("fake-secret-2"))
    }

    @Test("disableAllHooks after precedence and allowManagedHooksOnly")
    func hookSwitches() async throws {
        // User says disable all, project says false: project wins for that project, user hooks stay off.
        let disabled = await scan(extra: [
            "/h/.claude/settings.json":
                #"{"disableAllHooks":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"a"}]}]}}"#
        ])
        #expect(try !item(disabled, .hooks, "Stop · a").enabled)
        #expect(try item(disabled, .hooks, "PostToolUse · npx").enabled)

        let managedOnly = await scan(extra: [
            "/managed/managed-settings.json":
                #"{"allowManagedHooksOnly":true,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"policy"}]}]}}"#
        ])
        #expect(try item(managedOnly, .hooks, "Stop · policy").enabled)
        #expect(try item(managedOnly, .hooks, "Stop · policy").bucket == .readonly)
        #expect(try !item(managedOnly, .hooks, "PostToolUse · npx").enabled)
        #expect(try !item(managedOnly, .hooks, "SessionStart · start.sh").enabled)
    }

    @Test("Glob and command summary")
    func helpers() {
        #expect(Glob.matches("/p/.claude/rules/**", "/p/.claude/rules/a/b.md"))
        #expect(Glob.matches("**/CLAUDE.md", "/x/y/CLAUDE.md"))
        #expect(Glob.matches("/p/*.md", "/p/CLAUDE.md"))
        #expect(!Glob.matches("/p/*.md", "/p/sub/CLAUDE.md"))
        #expect(!Glob.matches("/p/a?.md", "/p/a/.md"))
        #expect(Glob.matches("/p/(x).md", "/p/(x).md"))
        #expect(CommandSummary.executable("FOO=bar BAZ=1 \"/usr/bin/my tool\" --secret x") == "my")
        #expect(CommandSummary.executable("env TOKEN=1 node server.js") == "node")
        #expect(CommandSummary.executable("") == "command")
    }
}
