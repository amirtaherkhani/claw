import XCTest

/// M4.8: the write flows end to end in the real app, on a fake home folder, checked on disk afterwards.
/// `CLAW_NO_CLAUDE=1` keeps the app from running a real `claude`, so Claw makes every change itself, the same on every
/// Mac; the contract tests cover the `claude` route. Nothing here reads or changes the real `~/.claude`.
final class FlowTests: XCTestCase {
    private var home: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        home = FileManager.default.temporaryDirectory.appendingPathComponent("claw-flow-\(UUID().uuidString)")
        let root = home.path
        let files = [
            ".claude/settings.json":
                #"{"enabledPlugins":{"kit@gh":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/echo done"}]}]}}"#,
            ".claude/plugins/known_marketplaces.json": #"{"gh":{"source":{"source":"github","repo":"o/m"}}}"#,
            ".claude/plugins/cache/kit/skills/lint/SKILL.md": "---\nname: lint\ndescription: Lints\n---\n",
            ".claude/CLAUDE.md": "# Mine",
            ".claude/skills/sample/SKILL.md": "---\nname: sample\ndescription: A sample skill\n---\n",
            ".claude/agents/reviewer.md": "---\nname: reviewer\ndescription: Reviews code\n---\n",
            // With CLAUDE_CONFIG_DIR set, Claude Code keeps `.claude.json` inside that folder.
            ".claude/.claude.json": #"{"projects":{"\#(root)/work/app":{}}}"#,
            "work/app/.mcp.json": #"{"mcpServers":{"db":{"command":"/bin/cat"}}}"#,
            // Approved, so the server starts on and the flow turns it off.
            "work/app/.claude/settings.json": #"{"enabledMcpjsonServers":["db"]}"#,
        ]
        for (path, text) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        app = XCUIApplication()
        app.launchEnvironment["HOME"] = root
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude").path
        app.launchEnvironment["CLAW_NO_CLAUDE"] = "1"
        app.launch()
        scan()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Flows

    func testDisablePlugin() throws {
        try toggle(page: "Plugins", bucket: "Read-only", name: "kit")
        apply(1)
        XCTAssertEqual(try value("enabledPlugins", "kit@gh") as? Bool, false)
    }

    func testDisableSkill() throws {
        try toggle(page: "Skills", bucket: "Yours", name: "sample")
        apply(1)
        XCTAssertEqual(try value("skillOverrides", "sample") as? String, "off")
    }

    func testExcludeRule() throws {
        try toggle(page: "Rules", bucket: "Yours", name: nil)
        apply(1)
        let excludes = try value("claudeMdExcludes") as? [String] ?? []
        XCTAssertTrue(excludes.contains { $0.hasSuffix(".claude/CLAUDE.md") }, "\(excludes)")
    }

    func testDenySubagent() throws {
        try toggle(page: "Subagents", bucket: "Yours", name: "reviewer")
        apply(1)
        let deny = try value("permissions", "deny") as? [String] ?? []
        XCTAssertTrue(deny.contains("Agent(reviewer)"), "\(deny)")
    }

    func testDisableMcpServer() throws {
        try toggle(page: "MCP servers", bucket: "Yours", name: "db")
        apply(1)
        let disabled = try value("disabledMcpjsonServers") as? [String] ?? []
        XCTAssertEqual(disabled, ["db"])
    }

    func testDisableAndReenableHook() throws {
        try toggle(page: "Hooks", bucket: "Yours", name: nil)
        apply(1)
        XCTAssertNil(try value("hooks"), "the hook left the file for Claw's stash")

        // Apply scans again; the hook is now listed from Claw's stash, off, with its switch.
        try toggle(page: "Hooks", bucket: "Yours", name: nil)
        apply(1)
        let stop = try value("hooks", "Stop") as? [[String: Any]]
        XCTAssertEqual(stop?.count, 1, "the hook is back where it was")
    }

    func testRemoveSkillAndRestore() throws {
        let skill = home.appendingPathComponent(".claude/skills/sample/SKILL.md")
        open("Skills")
        try openBucket("Yours")
        let details = app.buttons["Details for sample"]
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        details.click()
        let remove = app.buttons["Move to backup"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.click() }
        apply(1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.path), "the skill moved to the backup")

        open("History")
        let restore = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Restore: ")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        restore.click()
        let confirm = app.buttons["Restore"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        waitUntilEnabled(confirm)
        confirm.click()
        XCTAssertTrue(text("Restored").waitForExistence(timeout: 30))
        app.buttons["Done"].firstMatch.click()
        XCTAssertEqual(
            try String(contentsOf: skill, encoding: .utf8), "---\nname: sample\ndescription: A sample skill\n---\n")
    }

    // MARK: Helpers

    /// SwiftUI text reaches XCUITest on macOS as the element's value, not its label.
    private func text(_ part: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", part)).firstMatch
    }

    private func open(_ page: String) {
        let button = app.buttons["rail.\(page)"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no rail button for \(page)")
        button.click()
    }

    private func scan() {
        open("Overview")
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Scan all")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.click()
        XCTAssertTrue(text("items enabled").waitForExistence(timeout: 40), "the scan did not finish")
    }

    /// The owner node of a page's flow: "Yours", "Read-only" or "Needs attention".
    private func openBucket(_ bucket: String) throws {
        let node = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(bucket),")).firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 10), "no \(bucket) node")
        node.click()
    }

    /// Opens the page (and bucket), then flips the item's switch: by name, or the only switch there.
    private func toggle(page: String, bucket: String?, name: String?) throws {
        open(page)
        if let bucket {
            try openBucket(bucket)
        } else {
            let node = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", 1")).firstMatch
            XCTAssertTrue(node.waitForExistence(timeout: 10), "no node with the item")
            node.click()
        }
        let predicate =
            name.map { NSPredicate(format: "label == %@", "Enable \($0)") }
            ?? NSPredicate(format: "label BEGINSWITH %@", "Enable ")
        let toggle = app.checkBoxes.matching(predicate).firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 10),
            "no switch on \(page); switches: \(app.checkBoxes.allElementsBoundByIndex.map(\.label))")
        toggle.click()
    }

    /// Review, Apply, wait for the result, close it, and let the scan that follows finish.
    private func apply(_ count: Int) {
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Review")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10), "nothing queued")
        review.click()
        let label = count == 1 ? "Apply 1 change" : "Apply \(count) changes"
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(label) button")
        waitUntilEnabled(button)
        button.click()
        XCTAssertTrue(text("Applied").waitForExistence(timeout: 30), "Apply did not finish")
        app.buttons["Done"].firstMatch.click()
        XCTAssertTrue(text(" enabled").waitForExistence(timeout: 40), "the scan after Apply did not finish")
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: element)
        wait(for: [enabled], timeout: 20)
    }

    /// The value at a key path in the fake `~/.claude/settings.json`.
    private func value(_ keys: String...) throws -> Any? {
        try keys.reduce(settings() as Any?) { ($0 as? [String: Any])?[$1] }
    }

    private func settings() throws -> [String: Any] {
        let data = try Data(contentsOf: home.appendingPathComponent(".claude/settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
