import Foundation
import Testing

@testable import ClawCore

/// Contract tests against the real `claude` CLI (ROADMAP M2.12, TECHNICAL-DESIGN section 12). They run only with
/// `CLAW_CONTRACT=1`, and only in a temporary folder that is both `HOME` and the parent of `CLAUDE_CONFIG_DIR`
/// (spike S8): nothing reaches the real `~/.claude`. CI runs them nightly on macOS (`.github/workflows/contract.yml`).
enum Contract {
    static let claude: String? = {
        let process = ProcessInfo.processInfo.environment
        guard process["CLAW_CONTRACT"] == "1" else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeCLI.locate(environment: process, home: home, fileSystem: LocalFileSystem())
    }()
    static let marketplace = "claw-contract"
    static let plugin = "kit@claw-contract"
}

private final class Sandbox: @unchecked Sendable {
    let path: String
    let env: ClaudeEnvironment
    let cli: ClaudeCLI

    init(claude: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claw-contract-\(UUID().uuidString)")
        path = url.resolvingSymlinksInPath().path
        env = ClaudeEnvironment(
            home: path, configDir: joinPath(path, ".claude"), managedDir: joinPath(path, "managed"), projects: [])
        cli = ClaudeCLI(executable: claude, environment: env, timeoutSeconds: 120)
        try makeMarketplace()
        try await claudeRun(["plugin", "marketplace", "add", joinPath(path, "mkt")])
        try await claudeRun(["plugin", "install", Contract.plugin, "--scope", "user"])
    }
    deinit { try? FileManager.default.removeItem(atPath: path) }

    private func makeMarketplace() throws {
        let files = [
            "mkt/.claude-plugin/marketplace.json":
                #"{"name":"claw-contract","owner":{"name":"Claw tests"},"plugins":[{"name":"kit","source":"./kit","description":"Contract test plugin"}]}"#,
            "mkt/kit/.claude-plugin/plugin.json": #"{"name":"kit","version":"1.0.0","description":"Contract test plugin"}"#,
            "mkt/kit/skills/hello/SKILL.md": "---\nname: hello\ndescription: says hello\n---\nHello\n",
        ]
        for (relative, text) in files {
            let file = joinPath(path, relative)
            try FileManager.default.createDirectory(
                atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: URL(fileURLWithPath: file))
        }
    }

    @discardableResult
    func claudeRun(_ arguments: [String]) async throws -> CommandResult {
        let result = try await cli.runner.run(executable: cli.executable, arguments: arguments, timeoutSeconds: 120)
        guard result.exitCode == 0 else { throw CommandError.failed(exitCode: result.exitCode) }
        return result
    }

    /// What `claude plugin list --json` says about the test plugin: nil when it is not installed.
    func listed() async throws -> PluginRecord? {
        try await cli.pluginList().plugins.first { $0.id == Contract.plugin }
    }

    func commands(projects: [String] = []) throws -> WriteCommands {
        let env = self.env.with(projects: projects)
        let cli = self.cli
        return WriteCommands(
            environment: env, fileSystem: LocalFileSystem(), store: try BackupStore(environment: env),
            stash: HookStash(environment: env), cli: cli, appVersion: ClawVersion.string, claudeVersion: nil,
            scan: { await ConfigScanner(environment: env, cli: cli).scan() })
    }

    func pluginItemId() async throws -> String {
        let env = self.env
        let result = await ConfigScanner(environment: env, cli: cli).scan()
        let item = try #require(result.items.first { $0.concept == .plugins && $0.name.hasPrefix("kit") })
        return item.id
    }

    /// The real configuration of the account running the tests must not know the test marketplace.
    static func expectRealConfigUntouched() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for file in [
            ".claude/settings.json", ".claude/plugins/known_marketplaces.json", ".claude/plugins/installed_plugins.json",
        ] {
            guard let data = FileManager.default.contents(atPath: joinPath(home, file)) else { continue }
            #expect(!String(decoding: data, as: UTF8.self).contains(Contract.marketplace), "\(file)")
        }
    }
}

@Suite("Contract: real claude CLI", .serialized, .enabled(if: Contract.claude != nil, "set CLAW_CONTRACT=1"))
struct ContractTests {
    @Test("The sandbox is the only place claude writes to")
    func isolation() async throws {
        let sandbox = try await Sandbox(claude: try #require(Contract.claude))
        let listed = try #require(try await sandbox.listed())
        #expect(listed.installPath.hasPrefix(sandbox.path))
        #expect(FileManager.default.fileExists(atPath: joinPath(sandbox.path, ".claude/.claude.json")))
        Sandbox.expectRealConfigUntouched()
    }

    @Test("Disable, enable and restore through Claw: plugin list agrees after each")
    func toggle() async throws {
        let sandbox = try await Sandbox(claude: try #require(Contract.claude))
        let commands = try sandbox.commands()
        let id = try await sandbox.pluginItemId()
        #expect(try await sandbox.listed()?.enabled == true)

        let plan = await commands.plan(ChangeRequest(action: .disable, selector: id))
        #expect(plan.output.contains("run: claude plugin disable \(Contract.plugin) --scope user"), "\(plan.output)")
        let off = await commands.apply(ChangeRequest(action: .disable, selector: id), dryRun: false)
        #expect(off.exitCode == 0, "\(off.output)")
        #expect(try await sandbox.listed()?.enabled == false)

        let on = await commands.apply(ChangeRequest(action: .enable, selector: id), dryRun: false)
        #expect(on.exitCode == 0, "\(on.output)")
        #expect(try await sandbox.listed()?.enabled == true)

        let first = try #require(try BackupStore(environment: sandbox.env).ids().first)
        let restored = await commands.restore(id: first, accept: [], dryRun: false)
        #expect(restored.exitCode == 0, "\(restored.output)")
        #expect(try await sandbox.listed()?.enabled == true)
        Sandbox.expectRealConfigUntouched()
    }

    @Test("A dry run changes nothing that claude can see")
    func dryRun() async throws {
        let sandbox = try await Sandbox(claude: try #require(Contract.claude))
        let id = try await sandbox.pluginItemId()
        let settings = try Data(contentsOf: URL(fileURLWithPath: sandbox.env.userSettingsFile))
        let dry = await (try sandbox.commands()).apply(ChangeRequest(action: .disable, selector: id), dryRun: true)
        #expect(dry.exitCode == 0, "\(dry.output)")
        #expect(try await sandbox.listed()?.enabled == true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: sandbox.env.userSettingsFile)) == settings)
    }

    @Test("Remove uninstalls through claude, and plugin list no longer has it")
    func remove() async throws {
        let sandbox = try await Sandbox(claude: try #require(Contract.claude))
        let id = try await sandbox.pluginItemId()
        let plan = await (try sandbox.commands()).plan(ChangeRequest(action: .remove, selector: id))
        #expect(plan.output.contains("run: claude plugin uninstall"))
        let removed = await (try sandbox.commands()).apply(ChangeRequest(action: .remove, selector: id), dryRun: false)
        #expect(removed.exitCode == 0, "\(removed.output)")
        #expect(try await sandbox.listed() == nil)
        Sandbox.expectRealConfigUntouched()
    }

    @Test("A project's .mcp.json server is removed by claude mcp remove, and Claw checks the file")
    func removeProjectServer() async throws {
        let sandbox = try await Sandbox(claude: try #require(Contract.claude))
        let project = joinPath(sandbox.path, "proj")
        let mcpJson = joinPath(project, ".mcp.json")
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        let text = #"{"mcpServers":{"db":{"command":"/bin/echo"},"keep":{"command":"/bin/echo"}}}"#
        try Data(text.utf8).write(to: URL(fileURLWithPath: mcpJson))
        let commands = try sandbox.commands(projects: [project])
        let env = sandbox.env.with(projects: [project])
        let scan = await ConfigScanner(environment: env, cli: sandbox.cli).scan()
        let server = try #require(scan.items.first { $0.concept == .mcp && $0.name == "db" && $0.scope == .project })
        let request = ChangeRequest(action: .remove, selector: server.id, project: project)
        let plan = await commands.plan(request)
        #expect(plan.output.contains("run: claude mcp remove db --scope project"), "\(plan.output)")
        let removed = await commands.apply(request, dryRun: false)
        #expect(removed.exitCode == 0, "\(removed.output)")
        let after = try JSONValue.parse(try Data(contentsOf: URL(fileURLWithPath: mcpJson)))
        #expect(after["mcpServers"]?["db"] == nil)
        #expect(after["mcpServers"]?["keep"] != nil)
        Sandbox.expectRealConfigUntouched()
    }
}
