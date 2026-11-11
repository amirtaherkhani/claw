import Foundation

/// The scope switch (PRD F13, ROADMAP M4.5): which settings file a change is written to, what that means, and what
/// it needs. MCP servers have scopes of their own, explained separately (FR-F13-3) [V S1, S7].
public enum ScopeRules {
    public enum Request: Sendable, Equatable {
        case switchTo(SettingsScope)
        /// Project and Local write into the active project, so one has to be chosen first (FR-F13-2).
        case chooseProject(for: SettingsScope)
    }

    public static func request(_ scope: SettingsScope, activeProject: String?) -> Request {
        switch scope {
        case .project, .local: activeProject == nil ? .chooseProject(for: scope) : .switchTo(scope)
        case .user, .managed: .switchTo(scope)
        }
    }

    /// Where a scope writes, with `~` for the home folder, and what the person should know about that file.
    public struct Target: Sendable, Equatable {
        public let scope: SettingsScope
        /// `nil` when Project or Local has no active project.
        public let file: String?
        public let note: String?
    }

    public static func target(
        _ scope: SettingsScope, environment: ClaudeEnvironment, activeProject: String?, home: String
    ) -> Target {
        guard let write = WriteScope.resolve(scope, environment: environment, activeProject: activeProject) else {
            return Target(scope: scope, file: nil, note: "Choose an active project first.")
        }
        let file = ItemPresentation.abbreviate(write.file, home: home)
        switch scope {
        case .project:
            return Target(
                scope: scope, file: file,
                note: "Shared: this file is usually committed, so everyone on the project gets the change.")
        case .local:
            return Target(scope: scope, file: file, note: "Only you: this file is usually kept out of git.")
        case .user, .managed:
            return Target(scope: scope, file: file, note: nil)
        }
    }

    /// How the switch applies to MCP servers, whose scopes are not the settings scopes.
    public static func mcpExplanation(
        _ scope: SettingsScope, environment: ClaudeEnvironment, activeProject: String?, home: String
    ) -> [String] {
        let short = { (path: String) in ItemPresentation.abbreviate(path, home: home) }
        let claudeJson = short(environment.claudeJsonFile)
        guard let project = activeProject else {
            return [
                "MCP servers have their own scopes: user and local servers live in \(claudeJson), project servers in "
                    + "a project's .mcp.json.",
                "Choose an active project to turn servers off: Claude Code keeps that choice per project.",
            ]
        }
        let mcpJson = short(joinPath(project, ".mcp.json"))
        var lines = [
            "MCP servers have their own scopes: user servers live in \(claudeJson) for every project, local servers "
                + "in \(claudeJson) for \(short(project)) only, and project servers in \(mcpJson), which is shared.",
            "Turning off your own servers writes disabledMcpServers for \(short(project)) in \(claudeJson), whatever "
                + "the switch says.",
        ]
        if let write = WriteScope.resolve(scope, environment: environment, activeProject: project) {
            lines.append(
                "Turning off a server from \(mcpJson) writes disabledMcpjsonServers in \(short(write.file)), the "
                    + "file the switch chooses.")
        }
        return lines
    }
}
