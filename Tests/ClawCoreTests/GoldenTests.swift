import Foundation
import Testing

@testable import ClawCore

/// A fake machine on a real disk: `LocalFileSystem` reads it, so symlinks behave as they do for a user.
/// `$ROOT` stands for the temporary folder, in file contents and in the goldens.
private enum Fixture {
    static let files: [String: String] = [
        // Symlink target: see `links`.
        "home/dotfiles/claude-settings.json": """
        {"enabledPlugins":{"kit@gh":true,"nest@local-dev":true,"ghost@gh":true,"bad;name@gh":true},
         "skillOverrides":{"quiet":"off"},
         "permissions":{"deny":["Agent(blocked)"]},
         "claudeMdExcludes":["$ROOT/work/app/.claude/rules/**"],
         "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"API_KEY=fake-secret-1 /usr/local/bin/guard.sh --token fake-secret-2"}]}],
                  "Stop":[{"hooks":[{"type":"command","command":"rm -rf $ROOT/victim"}]}]}}
        """,
        "home/.claude.json": """
        {"mcpServers":{"remote":{"type":"http","url":"https://api.example.com/mcp?token=fake-secret-3","headers":{"Authorization":"Bearer fake-secret-4"}}},
         "projects":{"$ROOT/work/app":{"mcpServers":{"local-tool":{"command":"/opt/bin/tool","args":["--key","fake-secret-5"],"env":{"K":"fake-secret-6"}}},
                                       "disabledMcpServers":["remote"]}}}
        """,
        "home/.claude/CLAUDE.md": "# Mine",
        "home/.claude/commands/deploy.md": "---\ndescription: Deploy it\n---\nbody",
        "home/.claude/agents/reviewer.md": "---\nname: reviewer\ndescription: Reviews code\n---\n",
        "home/.claude/agents/blocked.md": "---\nname: blocked\ndescription: Denied\n---\n",
        "home/.claude/skills/writer/SKILL.md": "---\nname: writer\ndescription: Writes\n---\n",
        "home/.claude/skills/quiet/SKILL.md": "---\nname: quiet\ndescription: Switched off\n---\n",
        "home/.claude/skills/synced/shared/SKILL.md": "---\nname: shared\ndescription: From claude.ai\n---\n",
        "home/.claude/skills/bad; rm -rf x/SKILL.md": "no frontmatter",
        "home/.claude/plugins/known_marketplaces.json": """
        {"gh":{"source":{"source":"github","repo":"o/m"}},
         "local-dev":{"source":{"source":"directory","path":"$ROOT/dev/market"}}}
        """,
        "home/.claude/plugins/cache/kit/skills/lint/SKILL.md": "---\nname: lint\ndescription: Lints\n---\n",
        "home/.claude/plugins/cache/kit/commands/build.md": "Build",
        "home/.claude/plugins/cache/kit/agents/helper.md": "---\nname: helper\ndescription: Helps\n---\n",
        "home/.claude/plugins/cache/kit/.mcp.json": #"{"mcpServers":{"search":{"command":"node","args":["s.js"]}}}"#,
        "home/.claude/plugins/cache/kit/hooks/hooks.json":
            #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"${CLAUDE_PLUGIN_ROOT}/start.sh"}]}]}}"#,
        "dev/market/.claude-plugin/marketplace.json": #"{"name":"local-dev","plugins":[{"name":"nest","source":"./nest"}]}"#,
        "dev/market/.git/config": """
        [remote "origin"]
            url = https://someone:fake-secret-7@github.com/o/market.git
        """,
        "dev/market/nest/commands/scaffold.md": "Scaffold",
        "work/app/CLAUDE.md": "# Project",
        "work/app/.claude/rules/security.md": "Rule",
        "work/app/.claude/settings.json": #"{"enabledMcpjsonServers":["db"],"disabledMcpjsonServers":["off-server"]}"#,
        "work/app/.claude/settings.local.json":
            #"{"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command","command":"npx fmt"}]}]}}"#,
        "work/app/.claude/commands/test.md": "Run tests",
        "work/app/.claude/agents/planner.md": "---\nname: planner\ndescription: Plans\n---\n",
        "work/app/.claude/skills/migrate/SKILL.md": "---\nname: migrate\ndescription: Migrates\n---\n",
        "work/app/.mcp.json":
            #"{"mcpServers":{"db":{"command":"npx","args":["db-mcp"]},"off-server":{"command":"x"},"unapproved":{"url":"https://new.example.com"}}}"#,
        "managed/CLAUDE.md": "# Policy",
        "managed/managed-settings.json":
            #"{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"/opt/audit.sh"}]}]}}"#,
        "victim/keep.txt": "must survive the scan",
    ]

    /// Link to its destination, both relative to the root.
    static let links = ["home/.claude/settings.json": "home/dotfiles/claude-settings.json"]

    static let pluginList = """
        notice: a line the parser must skip
        [{"id":"kit@gh","scope":"user","enabled":true,"version":"1.2.0","installPath":"$ROOT/home/.claude/plugins/cache/kit"},\
        {"id":"nest@local-dev","scope":"user","enabled":true,"installPath":"$ROOT/dev/market/nest"},\
        {"id":"mine@skills-dir","scope":"user","enabled":true,"installPath":"$ROOT/home/.claude/skills/mine"},\
        {"id":"cloud@synced","scope":"synced","enabled":true,"installPath":"$ROOT/home/.claude/plugins/cache/cloud"},\
        {"id":"lost@removed-market","scope":"user","enabled":false,"installPath":"$ROOT/home/.claude/plugins/cache/lost"},\
        {"id":"bare","scope":"user","enabled":false,"installPath":"$ROOT/home/.claude/plugins/cache/bare"},\
        {"id":"evil;rm -rf ~@gh","scope":"user","enabled":true,"installPath":"$ROOT/victim"}]
        """

    static func create() throws -> String {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("claw-golden-\(UUID().uuidString)")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        // Resolved so that `/var` and `/private/var` cannot end up in the same result.
        let root = folder.resolvingSymlinksInPath().path

        for (path, text) in files {
            let url = URL(fileURLWithPath: joinPath(root, path))
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.replacingOccurrences(of: "$ROOT", with: root).utf8).write(to: url)
        }
        for (link, destination) in links {
            try manager.createSymbolicLink(atPath: joinPath(root, link), withDestinationPath: joinPath(root, destination))
        }
        return root
    }
}

@Suite("Golden scan results")
struct GoldenTests {
    enum Variant: String, CaseIterable {
        case mac, folder
        case macWithoutCLI = "mac-no-cli"
    }

    func scan(_ variant: Variant, root: String) async -> ScanResult {
        let project = joinPath(root, "work/app")
        let env = ClaudeEnvironment(
            home: joinPath(root, "home"), managedDir: joinPath(root, "managed"), projects: [project])
        let cli = ClaudeCLI(
            executable: "/bin/claude",
            runner: FakeRunner(responses: [
                "--version": ok("2.1.316 (Claude Code)"),
                "plugin list --json": ok(Fixture.pluginList.replacingOccurrences(of: "$ROOT", with: root)),
            ]))
        return await ConfigScanner(
            environment: env, target: variant == .folder ? .folder(project) : .mac,
            fileSystem: LocalFileSystem(), cli: variant == .macWithoutCLI ? nil : cli
        ).scan()
    }

    /// The scan as stable text: fixed times, `$ROOT` for the temporary folder.
    func text(_ result: ScanResult, root: String) throws -> String {
        let stable = ScanResult(
            target: result.target, startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 0),
            partial: result.partial, claudeCodeVersion: result.claudeCodeVersion,
            items: result.items, problems: result.problems)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(stable), as: UTF8.self)
            .replacingOccurrences(of: root, with: "$ROOT") + "\n"
    }

    func goldenFile(_ variant: Variant) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Goldens/\(variant.rawValue).json")
    }

    /// To accept a change on purpose: `CLAW_UPDATE_GOLDENS=1 swift test --filter GoldenTests`, then review the diff.
    @Test("A scan matches its golden", arguments: Variant.allCases)
    func matchesGolden(_ variant: Variant) async throws {
        let root = try Fixture.create()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let actual = try text(await scan(variant, root: root), root: root)
        let file = goldenFile(variant)

        if ProcessInfo.processInfo.environment["CLAW_UPDATE_GOLDENS"] == "1" {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(actual.utf8).write(to: file)
            return
        }
        let expected = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let (left, right) = (actual.components(separatedBy: "\n"), expected.components(separatedBy: "\n"))
        let line = zip(left, right).enumerated().first { $0.element.0 != $0.element.1 }
        #expect(line == nil, "\(variant.rawValue).json line \((line?.offset ?? 0) + 1) differs")
        #expect(left.count == right.count)
    }

    @Test("Every ownership each concept can have appears in the expected bucket")
    func ownershipCoverage() async throws {
        let root = try Fixture.create()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let items = await scan(.mac, root: root).items

        let expected: [Concept: Set<Ownership>] = [
            .plugins: [.personal, .market, .synced, .orphan],
            .skills: [.personal, .synced, .plugin],
            .commands: [.personal, .plugin],
            .agents: [.personal, .plugin],
            .rules: [.personal, .managed],
            .mcp: [.personal, .plugin],
            .hooks: [.personal, .plugin, .managed],
        ]
        #expect(Set(expected.keys) == Set(Concept.allCases))
        for (concept, ownerships) in expected {
            let found = items.filter { $0.concept == concept }
            #expect(Set(found.map(\.classification.ownership)) == ownerships, "\(concept)")
        }
        #expect(items.allSatisfy { $0.bucket == $0.classification.ownership.bucket })
    }

    @Test("A folder scan lists only that folder's project and local scope (FR-F02-2)")
    func folderScanScope() async throws {
        let root = try Fixture.create()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = await scan(.folder, root: root)
        let project = joinPath(root, "work/app")

        #expect(!result.items.isEmpty)
        for item in result.items {
            #expect(item.projectPath == project, "\(item.id)")
            #expect(item.scope == .project || item.scope == .local, "\(item.id)")
        }
        // Other scopes still decide state: the user's excludes switch this project rule off.
        let rule = try #require(result.items.first { $0.name == ".claude/rules/security.md" })
        #expect(!rule.enabled)
    }

    @Test("Only items proven Personal offer Edit")
    func editNeedsProof() async throws {
        let root = try Fixture.create()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let items = await scan(.mac, root: root).items
        #expect(!items.isEmpty)
        #expect(items.filter(\.capabilities.edit).allSatisfy { $0.classification.ownership == .personal })
    }

    @Test("A symlinked settings file is read through the link and stays a link")
    func symlinkedDotfile() async throws {
        let root = try Fixture.create()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let link = joinPath(root, "home/.claude/settings.json")
        let items = await scan(.mac, root: root).items

        let kit = try #require(items.first { $0.concept == .plugins && $0.name == "kit" })
        #expect(kit.enabledByFile == link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link).hasSuffix("dotfiles/claude-settings.json"))
    }

    @Test("Hostile ids are refused, hostile folders stay data, and nothing runs", arguments: Variant.allCases)
    func hostileInput(_ variant: Variant) async throws {
        let root = try Fixture.create()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let result = await scan(variant, root: root)

        #expect(!result.items.contains { $0.concept == .plugins && $0.id.contains("rm -rf") })
        #expect(!result.items.contains { $0.concept == .plugins && $0.id.contains("bad;name") })
        if variant == .mac {
            #expect(result.problems.contains { $0.message.contains("unsafe id") })
        }
        #expect(FileManager.default.fileExists(atPath: joinPath(root, "victim/keep.txt")))
    }

    @Test("No fixture secret reaches a result", arguments: Variant.allCases)
    func noSecrets(_ variant: Variant) async throws {
        let root = try Fixture.create()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let output = try text(await scan(variant, root: root), root: root)
        #expect(!output.contains("fake-secret"))
    }
}
