import Foundation

/// Display text for items, shared by the app and tests. No UI framework types here.
public enum ItemPresentation {
    public static func bucketTitle(_ bucket: Bucket) -> String {
        switch bucket {
        case .yours: "Yours"
        case .readonly: "Read-only"
        case .attention: "Needs attention"
        }
    }

    public static func bucketSubtitle(_ bucket: Bucket) -> String {
        switch bucket {
        case .yours: "Edit, disable or remove"
        case .readonly: "Disable or uninstall, not edit"
        case .attention: "Missing source or broken"
        }
    }

    public static func conceptTitle(_ concept: Concept) -> String {
        switch concept {
        case .plugins: "Plugins"
        case .skills: "Skills"
        case .commands: "Commands"
        case .rules: "Rules"
        case .agents: "Subagents"
        case .mcp: "MCP servers"
        case .hooks: "Hooks"
        }
    }

    public static func conceptSingular(_ concept: Concept) -> String {
        switch concept {
        case .plugins: "Plugin"
        case .skills: "Skill"
        case .commands: "Command"
        case .rules: "Rule"
        case .agents: "Subagent"
        case .mcp: "MCP server"
        case .hooks: "Hook"
        }
    }

    /// What the concept is, one line, for page headers.
    public static func conceptSummary(_ concept: Concept) -> String {
        switch concept {
        case .plugins: "Bundles of skills, commands, subagents, hooks and MCP servers, installed from marketplaces."
        case .skills: "Folders with a SKILL.md that Claude loads when relevant or you call by name."
        case .commands: "Markdown files that become slash commands."
        case .rules: "CLAUDE.md memory and rules files loaded into every session."
        case .agents: "Specialised subagents with their own prompt and tools."
        case .mcp: "Servers that give Claude extra tools and data."
        case .hooks: "Commands Claude Code runs on events such as before a tool runs."
        }
    }

    /// One or two letters for the row badge.
    public static func monogram(_ name: String) -> String {
        name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    /// "1 item", "2 items". English only until the String Catalog arrives.
    public static func counted(_ count: Int, _ singular: String) -> String {
        "\(count) \(singular)\(count == 1 ? "" : "s")"
    }

    /// The "Kind" column: plugin origin, MCP transport, hook handler type, or the concept.
    public static func kind(_ item: Item) -> String {
        switch item.concept {
        case .mcp, .hooks:
            let head = item.description.split(separator: " ").first.map(String.init) ?? ""
            return head.isEmpty ? conceptSingular(item.concept) : head
        case .plugins:
            return item.classification.ownership == .personal ? "Local" : conceptSingular(.plugins)
        default:
            return conceptSingular(item.concept)
        }
    }

    public static func scopeTitle(_ scope: ItemScope) -> String {
        switch scope {
        case .managed: "Managed"
        case .user: "User"
        case .project: "Project"
        case .local: "Local"
        case .plugin: "Plugin"
        case .synced: "claude.ai"
        }
    }

    /// File path part of an item's location (hooks add ` › hooks.Event[0]…`).
    public static func file(_ item: Item) -> String {
        item.location.components(separatedBy: " › ").first ?? item.location
    }

    /// Shows `~` instead of the home folder.
    public static func abbreviate(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// The note shown at the top of the detail view.
    public static func note(_ item: Item) -> String {
        switch item.classification.ownership {
        case .personal:
            "You own this. Edit it, turn it off, or remove it; every change is backed up first."
        case .market:
            "Installed from a marketplace. You can turn it off or uninstall it; change the source upstream."
        case .synced:
            "Synced from your claude.ai account. Manage it on claude.ai."
        case .plugin:
            "Part of plugin \(item.providedBy ?? "?"). Turn the plugin on or off instead."
        case .managed:
            "Set by your organization's managed policy. Read-only."
        case .orphan:
            "Its source is missing. Remove the record, or add its marketplace again."
        }
    }

    public static func controlState(_ status: VerificationStatus) -> String {
        switch status {
        case .verified: "Verified in the Claude Code docs"
        case .assumed: "Assumed"
        case .unknown: "Not verified yet (see docs/spikes.md)"
        }
    }

    /// What happens when the change is applied.
    public static func how(_ item: Item) -> String {
        switch item.control.mechanism {
        case .enabledPlugins:
            "Sets the plugin's entry in enabledPlugins. Open sessions need /reload-plugins or a restart."
        case .skillOverrides:
            "Sets skillOverrides. Claude Code reads it when settings reload."
        case .claudeMdExcludes:
            "Adds the file's path to claudeMdExcludes. The file itself is not touched."
        case .permissionsDeny:
            "Adds a permissions.deny rule for this subagent."
        case .disabledMcpjsonServers:
            "Adds the server to disabledMcpjsonServers for this project."
        case .disabledMcpServers:
            "Adds the server to the project's disabledMcpServers in ~/.claude.json."
        case .hookStash:
            "Claude Code has no per-hook switch, so Claw removes the entry and keeps a copy to restore."
        case .syncSetting:
            "Synced skills can only be turned off all together (syncClaudeAiSkills)."
        case .parentPlugin:
            "Controlled by its plugin: \(item.control.key)."
        case .none:
            "No switch exists for this item."
        }
    }

    public struct MetaRow: Sendable, Equatable, Identifiable {
        public let key: String
        public let value: String
        public let id: Int
    }

    /// "On", "Off (set by project)", or "Off (turned off by Claw)" for a hook in Claw's stash.
    public static func stateText(_ item: Item) -> String {
        if !item.enabled, item.enabledBy == HookStash.turnedOffBy { return "Off (turned off by Claw)" }
        return (item.enabled ? "On" : "Off") + (item.enabledBy.map { " (set by \($0))" } ?? "")
    }

    public static func meta(_ item: Item, home: String) -> [MetaRow] {
        var pairs: [(String, String)] = [
            ("Owner", "\(bucketTitle(item.bucket)) (rule \(item.classification.rule))"),
            ("Scope", scopeTitle(item.scope)),
            ("Location", abbreviate(item.location, home: home)),
        ]
        if let plugin = item.providedBy { pairs.append(("Provided by", plugin)) }
        if let project = item.projectPath { pairs.append(("Project", abbreviate(project, home: home))) }
        pairs.append(("State", stateText(item)))
        for (index, evidence) in item.classification.evidence.enumerated() {
            pairs.append((index == 0 ? "Why" : "", evidence.replacingOccurrences(of: home + "/", with: "~/")))
        }
        return pairs.enumerated().map { MetaRow(key: $0.element.0, value: $0.element.1, id: $0.offset) }
    }
}
