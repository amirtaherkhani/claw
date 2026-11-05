import XCTest

/// Drives the real app on a fake home folder, so it never reads or changes the real `~/.claude`.
final class SmokeTests: XCTestCase {
    private static let pages = [
        "Overview", "Scan", "Projects", "Plugins", "Skills", "Commands", "Rules", "Subagents", "MCP servers", "Hooks",
        "History",
    ]

    private var home: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        home = FileManager.default.temporaryDirectory.appendingPathComponent("claw-ui-\(UUID().uuidString)")
        let files = [
            ".claude/settings.json": #"{"permissions":{"deny":[]}}"#,
            ".claude/CLAUDE.md": "# Sample rules",
            ".claude/skills/sample/SKILL.md": "---\nname: sample\ndescription: A sample skill\n---\n",
            ".claude/commands/hello.md": "Say hello",
        ]
        for (path, text) in files {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        app = XCUIApplication()
        app.launchEnvironment["HOME"] = home.path
        app.launchEnvironment["CLAUDE_CONFIG_DIR"] = home.appendingPathComponent(".claude").path
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: home)
    }

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
        let start = app.buttons["Scan all"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.click()
        XCTAssertTrue(text("items enabled").waitForExistence(timeout: 40), "the scan did not finish")
    }

    /// Audit findings that are known and accepted; any other finding fails the test (`docs/accessibility-m3.md`).
    private static func isExplained(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        switch issue.auditType {
        case .contrast:
            // Measured from rendered pixels, and it flags small text whose colours measure 5.2:1 or better.
            return true
        case .sufficientElementDescription:
            // The window and split view containers: VoiceOver reads the controls inside them, not the group.
            // On CI the virtual Touch Bar also appears: a system element with nothing of Claw's in it.
            return issue.element?.elementType == .group || issue.element?.elementType == .touchBar
        case .action:
            // The system toolbar `Menu`.
            return issue.element?.elementType == .menuButton
        case .parentChild:
            // Seen on macOS 26 only: a 14-point group at the window's top left, the size of a window button.
            return issue.element?.elementType == .group && issue.element?.frame.size == CGSize(width: 14, height: 14)
        default:
            return false
        }
    }

    func testEveryPageOpensFromTheRail() {
        for page in Self.pages {
            open(page)
            XCTAssertTrue(text(page).waitForExistence(timeout: 5), "\(page) did not open")
        }
    }

    func testScanListsItemsFromTheFakeHome() {
        scan()
        open("Skills")
        let yours = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Yours")).firstMatch
        XCTAssertTrue(yours.waitForExistence(timeout: 5))
        yours.click()
        XCTAssertTrue(text("sample").waitForExistence(timeout: 5))
    }

    /// What the keyboard reaches with default system settings; `docs/accessibility-m3.md` lists what is left.
    func testKeyboardScansAndOpensPages() {
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(text("items enabled").waitForExistence(timeout: 40), "the scan did not finish")

        let pages = ["2": "Scan all configuration", "3": "Manage project folders", "5": "Skills", "1": "items enabled"]
        for (key, expected) in pages {
            app.typeKey(key, modifierFlags: .command)
            XCTAssertTrue(text(expected).waitForExistence(timeout: 5), "command-\(key) did not open \(expected)")
        }
    }

    func testEscapeClosesTheAddPluginSheet() {
        open("Plugins")
        app.buttons["Add plugin…"].firstMatch.click()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Escape did not close the sheet")
    }

    func testAddPluginSheetOpensAndCloses() {
        open("Plugins")
        let add = app.buttons["Add plugin…"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.click()
    }

    func testEveryPagePassesTheAccessibilityAudit() throws {
        scan()
        // Collected rather than failed one by one: the audit stops at the first finding it is told to report,
        // and its own message does not say which element it means.
        var unexplained: [String] = []
        for page in Self.pages {
            open(page)
            try app.performAccessibilityAudit { issue in
                if !Self.isExplained(issue) {
                    let element = issue.element
                    unexplained.append(
                        "\(page): \(issue.compactDescription), \(element?.description ?? "no element"), "
                            + "frame \(element?.frame ?? .zero), label '\(element?.label ?? "")'")
                }
                return true
            }
        }
        XCTAssertEqual(unexplained, [], unexplained.joined(separator: "\n"))
    }
}
