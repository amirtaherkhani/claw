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
            return issue.element?.elementType == .group
        case .action:
            // The system toolbar `Menu`.
            return issue.element?.elementType == .menuButton
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
        for page in Self.pages {
            open(page)
            try app.performAccessibilityAudit { Self.isExplained($0) }
        }
    }
}
