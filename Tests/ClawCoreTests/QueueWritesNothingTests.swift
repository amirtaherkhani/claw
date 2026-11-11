import Foundation
import Testing

@testable import ClawCore

/// M4.1: switches, removals, the bulk bar and the queue's previews only change the queue in memory. On a real
/// temporary HOME, every byte, modification time and folder must be the same afterwards, and no backup or stash
/// folder may appear. Nothing here touches the real `~/.claude`.
@Suite("Toggling writes nothing")
struct QueueWritesNothingTests {
    struct Entry: Equatable {
        let data: Data?
        let modified: Date?
    }

    final class Home: @unchecked Sendable {
        let path: String
        let project: String
        let env: ClaudeEnvironment

        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("claw-queue-\(UUID().uuidString)")
            path = url.resolvingSymlinksInPath().path
            project = joinPath(path, "work/app")
            env = ClaudeEnvironment(home: path, managedDir: joinPath(path, "managed"), projects: [project])
            let files: [String: String] = [
                env.userSettingsFile:
                    #"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/echo done"}]}]}}"#,
                env.claudeJsonFile: #"{"mcpServers":{"notes":{"command":"/bin/cat","env":{"TOKEN":"fake-secret-4"}}}}"#,
                joinPath(env.userSkillsDir, "tidy/SKILL.md"): "---\nname: tidy\ndescription: Tidy files\n---\nBody\n",
                joinPath(env.configDir, "agents/reviewer.md"): "---\nname: reviewer\ndescription: Reviews\n---\nBody\n",
                joinPath(env.configDir, "commands/ship.md"): "Ship it\n",
                env.projectSettingsFile(project): #"{"permissions":{"allow":["Bash(ls)"]}}"#,
                joinPath(env.projectSkillsDir(project), "lint/SKILL.md"): "---\nname: lint\ndescription: Lint\n---\nB\n",
                joinPath(project, "CLAUDE.md"): "# App\n",
            ]
            for (file, text) in files {
                try FileManager.default.createDirectory(
                    atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try Data(text.utf8).write(to: URL(fileURLWithPath: file))
            }
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        /// Every file and folder under HOME, with its bytes and modification time.
        func snapshot() throws -> [String: Entry] {
            var found: [String: Entry] = [:]
            let enumerator = try #require(FileManager.default.enumerator(atPath: path))
            while let relative = enumerator.nextObject() as? String {
                let full = joinPath(path, relative)
                let attributes = try FileManager.default.attributesOfItem(atPath: full)
                let isFolder = attributes[.type] as? FileAttributeType == .typeDirectory
                found[relative] = Entry(
                    data: isFolder ? nil : FileManager.default.contents(atPath: full),
                    modified: attributes[.modificationDate] as? Date)
            }
            return found
        }
    }

    @Test("Switches, removals, bulk actions, previews and a rescan leave every file as it was")
    func writesNothing() async throws {
        let home = try Home()
        let before = try home.snapshot()
        let scan = await ConfigScanner(environment: home.env, cli: nil).scan()
        let items = scan.items
        #expect(items.contains { $0.capabilities.toggle }, "the fixture needs items with a switch")
        #expect(items.contains { $0.capabilities.remove }, "the fixture needs items that can be removed")
        let scope = WriteScope.resolve(.project, environment: home.env, activeProject: home.project)

        var queue = ChangeQueue()
        for item in items { queue.toggle(item, writeScope: scope, home: home.path) }
        for item in items { queue.toggleRemoval(item, home: home.path) }
        for item in items where queue.effectiveEnabled(item) { queue.toggle(item, writeScope: nil, home: home.path) }
        for item in items {
            for action in [PendingChange.Action.enable, .disable, .remove] {
                _ = ChangeQueue.preview(item, action: action, writeScope: scope, home: home.path)
            }
        }
        #expect(!queue.isEmpty)
        let again = await ConfigScanner(environment: home.env, cli: nil).scan()
        let outcome = ScanOutcome(
            result: again, projects: [home.project], stopped: false, previous: scan, queue: queue)
        for change in outcome.queue.changes { queue.discard(change) }
        queue.clear()

        let after = try home.snapshot()
        #expect(Set(after.keys) == Set(before.keys), "files or folders were added or removed")
        for (path, entry) in before where after[path] != entry {
            Issue.record("\(path) changed")
        }
        let claw = joinPath(home.path, "Library/Application Support/Claw")
        #expect(!FileManager.default.fileExists(atPath: claw), "a backup or stash folder was created")
    }
}
