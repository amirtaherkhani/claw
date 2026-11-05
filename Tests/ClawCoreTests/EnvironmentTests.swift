import Foundation
import Testing

@testable import ClawCore

@Suite("Where the config lives")
struct EnvironmentTests {
    @Test("Without CLAUDE_CONFIG_DIR, .claude.json sits next to ~/.claude")
    func variableUnset() {
        let env = ClaudeEnvironment.current(environment: ["HOME": "/h"])
        #expect(env.claudeJsonFile == "/h/.claude.json")
    }

    @Test("With CLAUDE_CONFIG_DIR, .claude.json moves into that folder (S8)")
    func variableSet() {
        let env = ClaudeEnvironment.current(environment: ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/c"])
        #expect(env.claudeJsonFile == "/c/.claude.json")
    }

    @Test("CLAUDE_CONFIG_DIR set to ~/.claude still moves .claude.json inside it (S8)")
    func variableSetToDefaultFolder() {
        let env = ClaudeEnvironment.current(environment: ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/h/.claude"])
        #expect(env.claudeJsonFile == "/h/.claude/.claude.json")
    }

    @Test("Changing the projects keeps where .claude.json lives")
    func projectsKeepTheFile() {
        let unset = ClaudeEnvironment.current(environment: ["HOME": "/h"]).with(projects: ["/p"])
        let set = ClaudeEnvironment.current(environment: ["HOME": "/h", "CLAUDE_CONFIG_DIR": "/h/.claude"]).with(projects: ["/p"])
        #expect(unset.claudeJsonFile == "/h/.claude.json")
        #expect(set.claudeJsonFile == "/h/.claude/.claude.json")
        #expect(set.projects == ["/p"])
    }

    @Test("An empty CLAUDE_CONFIG_DIR counts as unset")
    func variableEmpty() {
        let env = ClaudeEnvironment.current(environment: ["HOME": "/h", "CLAUDE_CONFIG_DIR": ""])
        #expect(env.claudeJsonFile == "/h/.claude.json")
    }
}

@Suite("Resolving paths on disk")
struct ResolvingPathTests {
    private func temporaryFolder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return try #require(
            realpath(url.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })
    }

    @Test("A missing file resolves under the same spelling as its folder (F11)")
    func missingFileKeepsFolderSpelling() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let disk = LocalFileSystem()
        #expect(
            disk.resolvingSymlinks(joinPath(folder, "missing/deeper"))
                == joinPath(disk.resolvingSymlinks(folder), "missing/deeper"))
    }

    @Test("A link is followed even when the end of the path is missing")
    func linkBeforeMissingFile() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = joinPath(folder, "target")
        let link = joinPath(folder, "link")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let disk = LocalFileSystem()
        #expect(disk.resolvingSymlinks(joinPath(link, "missing")) == joinPath(disk.resolvingSymlinks(target), "missing"))
    }

    @Test("A missing file under a scan root is not reported as a link leaving the root (F11)")
    func missingFileIsNotRefused() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let config = joinPath(folder, "cfg")
        try FileManager.default.createDirectory(atPath: config, withIntermediateDirectories: true)
        let env = ClaudeEnvironment(home: joinPath(folder, "home"), configDir: config, managedDir: joinPath(folder, "managed"))
        let contained = ContainedFileSystem(LocalFileSystem(), environment: env)
        #expect(!contained.fileExists(joinPath(config, "CLAUDE.md")))
        #expect(contained.problems.isEmpty)
    }
}
