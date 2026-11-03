import Foundation

/// Where Claude Code keeps its configuration on this machine (TECHNICAL-DESIGN section 3.1).
public struct ClaudeEnvironment: Sendable, Equatable {
    public let home: String
    /// `~/.claude`, or `CLAUDE_CONFIG_DIR` when set [V `settings`].
    public let configDir: String
    /// `~/.claude/plugins`, or `CLAUDE_CODE_PLUGIN_CACHE_DIR` when set [V `plugins/loading`].
    public let pluginsDir: String
    /// Managed policy folder: `/Library/Application Support/ClaudeCode` on macOS [V `settings`].
    public let managedDir: String
    /// Registered project folders.
    public let projects: [String]

    public init(
        home: String,
        configDir: String? = nil,
        pluginsDir: String? = nil,
        managedDir: String? = nil,
        projects: [String] = []
    ) {
        self.home = home
        let config = configDir ?? joinPath(home, ".claude")
        self.configDir = config
        self.pluginsDir = pluginsDir ?? joinPath(config, "plugins")
        self.managedDir = managedDir ?? Self.defaultManagedDir
        self.projects = projects
    }

    /// Builds the environment from process variables. Empty variables count as unset.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        projects: [String] = []
    ) -> ClaudeEnvironment {
        func value(_ key: String) -> String? {
            guard let raw = environment[key], !raw.isEmpty else { return nil }
            return raw
        }
        let home = value("HOME") ?? FileManager.default.homeDirectoryForCurrentUser.path
        return ClaudeEnvironment(
            home: home,
            configDir: value("CLAUDE_CONFIG_DIR"),
            pluginsDir: value("CLAUDE_CODE_PLUGIN_CACHE_DIR"),
            projects: projects
        )
    }

    public static var defaultManagedDir: String {
        #if os(macOS)
            "/Library/Application Support/ClaudeCode"
        #else
            "/etc/claude-code"
        #endif
    }

    public var userSettingsFile: String { joinPath(configDir, "settings.json") }
    public var userSkillsDir: String { joinPath(configDir, "skills") }
    /// Skills synced from the claude.ai account [V `skills`].
    public var syncedSkillsDir: String { joinPath(userSkillsDir, "synced") }
    public var knownMarketplacesFile: String { joinPath(pluginsDir, "known_marketplaces.json") }
    public var installedPluginsFile: String { joinPath(pluginsDir, "installed_plugins.json") }
    public var managedSettingsFile: String { joinPath(managedDir, "managed-settings.json") }

    public func projectSettingsFile(_ project: String) -> String { joinPath(project, ".claude", "settings.json") }
    public func localSettingsFile(_ project: String) -> String { joinPath(project, ".claude", "settings.local.json") }
    public func projectSkillsDir(_ project: String) -> String { joinPath(project, ".claude", "skills") }
}
