import Foundation
import Testing

@testable import ClawCore

/// FR-F15-4: a hook Claw turned off stays in the Hooks list, shown "Off (turned off by Claw)", and can be turned
/// back on from there (M2.14).
@Suite("Stashed hooks in the list")
struct StashedHookListTests {
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
    static let stashDir = "/h/Library/Application Support/Claw/stash"

    static func entry(id: String, file: String, command: String = "/bin/s.sh --token fake-secret-9") -> HookStashEntry {
        HookStashEntry(
            id: id, sourceFile: file, event: "Stop", matcher: nil,
            handler: .object(["type": .string("command"), "command": .string(command)]),
            handlerText: #"{ "type": "command", "command": "\#(command)" }"#, groupText: nil,
            position: .init(groupIndex: 0, handlerIndex: 0), stashedAt: "2026-11-10T10-00-00Z")
    }

    static func encoded(_ entry: HookStashEntry) throws -> String {
        String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
    }

    func files() throws -> [String: String] {
        [
            "/h/.claude/settings.json": #"{"hooks":{}}"#,
            "/p/.claude/settings.json": #"{"theme":"dark"}"#,
            "\(Self.stashDir)/user-1.json": try Self.encoded(Self.entry(id: "user-1", file: "/h/.claude/settings.json")),
            "\(Self.stashDir)/proj-1.json": try Self.encoded(Self.entry(id: "proj-1", file: "/p/.claude/settings.json")),
            "\(Self.stashDir)/taken/old-1.json": try Self.encoded(
                Self.entry(id: "old-1", file: "/h/.claude/settings.json")),
        ]
    }

    func scan(_ target: ScanTarget = .mac) async throws -> (ScanResult, MemoryFileSystem) {
        let fs = MemoryFileSystem(try files())
        let result = await ConfigScanner(environment: Self.env, target: target, fileSystem: fs, cli: nil).scan()
        return (result, fs)
    }

    func stashed(_ result: ScanResult) -> [Item] {
        result.items.filter { $0.concept == .hooks && $0.control.mechanism == .hookStash && !$0.enabled }
    }

    @Test("A stashed hook is listed Off, turned off by Claw, with a switch")
    func listed() async throws {
        let (result, _) = try await scan()
        let items = stashed(result)
        #expect(items.count == 2)
        let user = try #require(items.first { $0.scope == .user })
        #expect(user.name == "Stop · s.sh")
        #expect(user.enabledBy == HookStash.turnedOffBy)
        #expect(user.capabilities.toggle)
        #expect(user.bucket == .yours)
        let project = try #require(items.first { $0.scope == .project })
        #expect(project.projectPath == "/p")
        let state = ItemPresentation.meta(user, home: "/h").first { $0.key == "State" }?.value
        #expect(state == "Off (turned off by Claw)")
    }

    @Test("Its command is never shown, and taken entries are not listed")
    func noSecretNoTaken() async throws {
        let (result, _) = try await scan()
        let text = String(decoding: try JSONEncoder().encode(result.items), as: UTF8.self)
        #expect(!text.contains("fake-secret-9"))
        #expect(!stashed(result).contains { $0.location.contains("old-1") })
    }

    @Test("A folder scan lists only that project's stashed hooks")
    func folderScan() async throws {
        let (result, _) = try await scan(.folder("/p"))
        #expect(stashed(result).map(\.scope) == [.project])
    }

    @Test("Turning it on plans the restore and takes it from the stash")
    func turnOn() async throws {
        let (result, fs) = try await scan()
        let user = try #require(stashed(result).first { $0.scope == .user })
        let change = try Planner(environment: Self.env, fileSystem: fs).setEnabled(
            user, enabled: true, writeScope: nil, activeProject: nil)
        #expect(change.stash == .take("user-1"))
        let after = String(decoding: try #require(change.edits.first).after, as: UTF8.self)
        #expect(after.contains("/bin/s.sh"))
        #expect(after.contains("Stop"))
    }

    @Test("On disk: turn off, scan again as after a restart, turn on: the settings mean the same again")
    func roundTrip() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath().path
        defer { try? FileManager.default.removeItem(atPath: home) }
        let env = ClaudeEnvironment(home: home, managedDir: joinPath(home, "managed"), projects: [])
        try FileManager.default.createDirectory(atPath: env.configDir, withIntermediateDirectories: true)
        let original = Data(
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/s.sh --token fake-secret-9"}]}]}}"#.utf8)
        try original.write(to: URL(fileURLWithPath: env.userSettingsFile))
        let pipeline = ApplyPipeline(
            environment: env, store: try BackupStore(environment: env), stash: HookStash(environment: env), cli: nil,
            appVersion: "0.1.0", claudeVersion: nil)
        let planner = Planner(environment: env, fileSystem: LocalFileSystem())
        func hooks() async -> [Item] {
            await ConfigScanner(environment: env, cli: nil).scan().items.filter { $0.concept == .hooks }
        }

        let on = try #require(await hooks().first)
        let off = try await pipeline.apply(
            [try planner.setEnabled(on, enabled: false, writeScope: nil, activeProject: nil)], title: "off")
        #expect(off.status == .applied, "\(off.failure ?? "")")

        let listed = try #require(await hooks().first)
        #expect(!listed.enabled)
        #expect(ItemPresentation.stateText(listed) == "Off (turned off by Claw)")

        let back = try await pipeline.apply(
            [try planner.setEnabled(listed, enabled: true, writeScope: nil, activeProject: nil)], title: "on")
        #expect(back.status == .applied, "\(back.failure ?? "")")
        // The last hook of a file takes its `hooks` keys with it, so it comes back with the same meaning.
        let now = try Data(contentsOf: URL(fileURLWithPath: env.userSettingsFile))
        #expect(try JSONValue.parse(now) == JSONValue.parse(original))
        let after = await hooks()
        #expect(after.count == 1)
        #expect(after.first?.enabled == true)
    }
}
