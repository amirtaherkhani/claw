import Foundation
import Testing

@testable import ClawCore

/// M4.5 (FR-F13-*): the scope switch decides which file a change is written to. Project and Local need an active
/// project, and choosing one without it asks for a project instead of switching. MCP servers have scopes of their
/// own, which the MCP page explains.
@Suite("Scope rules")
struct ScopeRulesTests {
    static let env = ClaudeEnvironment(home: "/h", managedDir: "/managed", projects: [])

    @Test("Project and Local without an active project ask for one; User always switches")
    func request() {
        #expect(ScopeRules.request(.project, activeProject: nil) == .chooseProject(for: .project))
        #expect(ScopeRules.request(.local, activeProject: nil) == .chooseProject(for: .local))
        #expect(ScopeRules.request(.project, activeProject: "/h/app") == .switchTo(.project))
        #expect(ScopeRules.request(.user, activeProject: nil) == .switchTo(.user))
    }

    @Test("Each scope names its file; Project warns that the file is shared, Local that it stays with you")
    func target() {
        let user = ScopeRules.target(.user, environment: Self.env, activeProject: nil, home: "/h")
        #expect(user.file == "~/.claude/settings.json")
        #expect(user.note == nil)
        let project = ScopeRules.target(.project, environment: Self.env, activeProject: "/h/app", home: "/h")
        #expect(project.file == "~/app/.claude/settings.json")
        #expect(project.note?.contains("committed") == true)
        let local = ScopeRules.target(.local, environment: Self.env, activeProject: "/h/app", home: "/h")
        #expect(local.file == "~/app/.claude/settings.local.json")
        #expect(local.note?.contains("Only you") == true)
        let none = ScopeRules.target(.project, environment: Self.env, activeProject: nil, home: "/h")
        #expect(none.file == nil)
    }

    @Test("The MCP page explains MCP scopes and where turning a server off is written")
    func mcp() {
        let lines = ScopeRules.mcpExplanation(.project, environment: Self.env, activeProject: "/h/app", home: "/h")
        let text = lines.joined(separator: "\n")
        #expect(text.contains("~/app/.mcp.json"))
        #expect(text.contains("~/.claude.json"))
        #expect(text.contains("disabledMcpjsonServers in ~/app/.claude/settings.json"))
        #expect(text.contains("disabledMcpServers"))
        let noProject = ScopeRules.mcpExplanation(.user, environment: Self.env, activeProject: nil, home: "/h")
        #expect(noProject.joined().contains("Choose an active project"))
    }
}
