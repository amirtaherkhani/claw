import Foundation
import Testing

@testable import ClawCore

private let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: ["/p"])
private let file = "/h/.claude/settings.json"
private let date = Date(timeIntervalSince1970: 1_793_865_245)

private func hook(_ event: String, _ group: Int, _ handler: Int, summary: String, matcher: String? = nil) -> Item {
    let label = matcher.map { " [\($0)]" } ?? ""
    return Item(
        concept: .hooks, key: "\(event)/\(group)/\(handler)", name: "\(event)\(label) · \(summary)",
        description: "command hook", scope: .user,
        classification: Classification(ownership: .personal, rule: "T", evidence: []),
        location: "\(file) › hooks.\(event)[\(group)].hooks[\(handler)]", enabled: true,
        control: ControlRef(mechanism: .hookStash, key: "stash", status: .verified),
        capabilities: Capabilities(edit: true, toggle: true, remove: true, removeLabel: "Remove entry", reason: nil))
}

private func planner(_ text: String) -> Planner {
    Planner(environment: env, fileSystem: MemoryFileSystem([file: text]))
}

private func after(_ change: PlannedChange) throws -> String {
    String(decoding: try #require(change.edits.first).after, as: UTF8.self)
}

private func stashed(_ change: PlannedChange) throws -> HookStashEntry {
    guard case .put(let entry) = change.stash else { throw PlanError(reason: "no stash") }
    return entry
}

private let twoHandlers = """
    {
      "theme": "dark",
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              { "type": "command", "command": "/bin/one.sh --token secret" },
              { "type": "command", "timeout": 5, "command": "/bin/two.sh" }
            ]
          },
          {
            "matcher": "Read",
            "hooks": [
              { "type": "command", "command": "/bin/three.sh" }
            ]
          }
        ]
      }
    }

    """

@Suite("Hook stash")
struct HookStashTests {
    @Test("Disabling a hook removes it and fills a stash entry")
    func put() throws {
        let change = try planner(twoHandlers).setEnabled(
            hook("PreToolUse", 0, 1, summary: "two.sh", matcher: "Bash"), enabled: false, writeScope: nil, activeProject: nil,
            date: date)
        guard case .put(let entry) = change.stash else {
            Issue.record("no stash")
            return
        }
        #expect(entry.sourceFile == file)
        #expect(entry.event == "PreToolUse")
        #expect(entry.matcher == "Bash")
        #expect(entry.position == .init(groupIndex: 0, handlerIndex: 1))
        #expect(entry.handler["command"]?.stringValue == "/bin/two.sh")
        #expect(entry.stashedAt == "2026-11-05T07-54-05Z")
        #expect(entry.id.hasPrefix("hook-pretooluse-"))
        #expect(!(try after(change)).contains("two.sh"))
        #expect(change.effect == .live)
    }

    @Test(
        "Handler restored in its place returns the same bytes", arguments: [(0, 0, "one.sh", "Bash"), (0, 1, "two.sh", "Bash")])
    func roundTrip(group: Int, handler: Int, summary: String, matcher: String) throws {
        let off = try planner(twoHandlers).setEnabled(
            hook("PreToolUse", group, handler, summary: summary, matcher: matcher), enabled: false, writeScope: nil,
            activeProject: nil, date: date)
        let entry = try stashed(off)
        let on = try planner(try after(off)).restore(entry)
        #expect(try after(on) == twoHandlers)
        #expect(on.stash == .take(entry.id))
    }

    @Test("A group that emptied comes back in its place, same bytes")
    func groupRoundTrip() throws {
        let off = try planner(twoHandlers).setEnabled(
            hook("PreToolUse", 1, 0, summary: "three.sh", matcher: "Read"), enabled: false, writeScope: nil, activeProject: nil,
            date: date)
        let entry = try stashed(off)
        #expect(!(try after(off)).contains("Read"))
        #expect(try after(try planner(try after(off)).restore(entry)) == twoHandlers)
    }

    @Test("The last hook of all: the keys go, and it comes back with the same meaning")
    func lastHook() throws {
        let text =
            "{\n  \"hooks\": {\n    \"Stop\": [\n      {\n        \"hooks\": [\n          {\"type\": \"command\", \"command\": \"/bin/s.sh\"}\n        ]\n      }\n    ]\n  }\n}\n"
        let off = try planner(text).setEnabled(
            hook("Stop", 0, 0, summary: "s.sh"), enabled: false, writeScope: nil, activeProject: nil, date: date)
        #expect(try after(off) == "{}\n")
        let entry = try stashed(off)
        let on = try planner(try after(off)).restore(entry)
        #expect(try JSONValue.parse(Data(try after(on).utf8)) == JSONValue.parse(Data(text.utf8)))
    }

    @Test("The group was removed meanwhile: it is made again")
    func recreatesGroup() throws {
        let off = try planner(twoHandlers).setEnabled(
            hook("PreToolUse", 0, 1, summary: "two.sh", matcher: "Bash"), enabled: false, writeScope: nil, activeProject: nil,
            date: date)
        let entry = try stashed(off)
        let changed = "{\n  \"hooks\": {\n    \"PreToolUse\": []\n  }\n}\n"
        let json = try JSONValue.parse(try #require(try planner(changed).restore(entry).edits.first).after)
        let group = try #require(json["hooks"]?["PreToolUse"]?.arrayValue?.first)
        #expect(group["matcher"]?.stringValue == "Bash")
        #expect(group["hooks"]?.arrayValue == [entry.handler])
    }

    @Test("The matcher now sits at another index: it goes in that group")
    func matcherMoved() throws {
        let off = try planner(twoHandlers).setEnabled(
            hook("PreToolUse", 1, 0, summary: "three.sh", matcher: "Read"), enabled: false, writeScope: nil, activeProject: nil,
            date: date)
        let entry = try stashed(off)
        let changed = #"{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"/bin/x"}]}]}}"#
        let json = try JSONValue.parse(try #require(try planner(changed).restore(entry).edits.first).after)
        #expect(json["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
        #expect(json["hooks"]?["PreToolUse"]?.arrayValue?.first?["hooks"]?.arrayValue?.count == 2)
    }

    @Test("An identical handler already there: no edit, and the stash is still taken")
    func identicalHandler() throws {
        let off = try planner(twoHandlers).setEnabled(
            hook("PreToolUse", 0, 1, summary: "two.sh", matcher: "Bash"), enabled: false, writeScope: nil, activeProject: nil,
            date: date)
        let entry = try stashed(off)
        let change = try planner(twoHandlers).restore(entry)
        #expect(change.edits.isEmpty)
        #expect(change.stash == .take(entry.id))
    }

    @Test("Enabling a scanned hook has nothing to do: it is already on")
    func enablingNeedsAnEntry() {
        #expect(throws: PlanError.self) {
            try planner(twoHandlers).setEnabled(
                hook("PreToolUse", 0, 0, summary: "one.sh", matcher: "Bash"), enabled: true, writeScope: nil, activeProject: nil)
        }
    }

    @Test("The store: private, listed, and taking keeps the file")
    func store() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let stash = HookStash(root: url.path)
        let entry = HookStashEntry(
            id: "hook-stop-abc", sourceFile: file, event: "Stop", matcher: nil, handler: .object(["type": .string("command")]),
            handlerText: "{}", groupText: nil, position: .init(groupIndex: 0, handlerIndex: 0), stashedAt: "t")
        try stash.put(entry)
        #expect(try stash.entries() == [entry])
        let path = joinPath(url.path, "hook-stop-abc.json")
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o700)
        #expect(throws: StaleFileError.self) { try stash.put(entry) }
        try stash.take(entry.id)
        #expect(try stash.entries().isEmpty)
        #expect(FileManager.default.fileExists(atPath: joinPath(url.path, "taken/hook-stop-abc.json")))
        #expect(throws: BackupError.self) { try stash.take("../evil") }
    }

    @Test("The default store is in Application Support")
    func defaultStore() {
        #expect(HookStash(environment: env).root == "/h/Library/Application Support/Claw/stash")
    }
}
