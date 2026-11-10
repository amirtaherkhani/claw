import Foundation
import Testing

@testable import ClawCore

/// `claude` must see the same configuration Claw reads: a test or a relocated config dir must never reach the real
/// `~/.claude` through an inherited `HOME`.
@Suite("Environment passed to claude")
struct ChildEnvironmentTests {
    @Test("HOME and CLAUDE_CONFIG_DIR come from the Claw environment, PATH from the parent")
    func setDir() {
        let env = ClaudeEnvironment(home: "/t/home", configDir: "/t/home/.claude")
        let child = ClaudeCLI.childEnvironment(
            for: env, parent: ["HOME": "/Users/real", "PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/Users/real/.claude"])
        #expect(child["HOME"] == "/t/home")
        #expect(child["CLAUDE_CONFIG_DIR"] == "/t/home/.claude")
        #expect(child["PATH"] == "/usr/bin")
    }

    @Test("An unset config dir is removed, not inherited")
    func unsetDir() {
        let env = ClaudeEnvironment(home: "/t/home")
        let child = ClaudeCLI.childEnvironment(
            for: env, parent: ["HOME": "/Users/real", "CLAUDE_CONFIG_DIR": "/Users/real/.claude"])
        #expect(child["HOME"] == "/t/home")
        #expect(child["CLAUDE_CONFIG_DIR"] == nil)
        #expect(child["CLAUDE_CODE_PLUGIN_CACHE_DIR"] == nil)
    }

    @Test("A moved plugin cache is passed on")
    func pluginCache() {
        let env = ClaudeEnvironment(home: "/t/home", pluginsDir: "/t/cache")
        let child = ClaudeCLI.childEnvironment(for: env, parent: ["CLAUDE_CODE_PLUGIN_CACHE_DIR": "/Users/real/x"])
        #expect(child["CLAUDE_CODE_PLUGIN_CACHE_DIR"] == "/t/cache")
    }

    @Test("ProcessRunner starts the child with exactly the given environment")
    func runnerPassesIt() async throws {
        let runner = ProcessRunner(environment: ["HOME": "/t/fake-home", "CLAW_MARK": "1"])
        let result = try await runner.run(executable: "/usr/bin/env", arguments: [], timeoutSeconds: 10)
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.contains("HOME=/t/fake-home"))
        #expect(lines.contains("CLAW_MARK=1"))
        #expect(!lines.contains { $0.hasPrefix("USER=") || $0.hasPrefix("LOGNAME=") })
    }

    @Test("ClaudeCLI built for an environment runs claude with it")
    func cliUsesIt() async throws {
        let env = ClaudeEnvironment(home: "/t/home2", configDir: "/t/home2/.claude")
        let cli = ClaudeCLI(executable: "/usr/bin/env", environment: env)
        let result = try await cli.runner.run(executable: "/usr/bin/env", arguments: [], timeoutSeconds: 10)
        let text = String(decoding: result.stdout, as: UTF8.self)
        #expect(text.contains("HOME=/t/home2\n"))
        #expect(text.contains("CLAUDE_CONFIG_DIR=/t/home2/.claude\n"))
    }
}
