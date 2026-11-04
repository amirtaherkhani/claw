import Foundation

/// What the Add project sheet found in a folder (PRD F03). Read-only.
public struct ProjectInspection: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public let path: String
        public let label: String
        public let found: Bool
        public var id: String { path }
    }

    public let folder: String
    public let rows: [Row]

    public var isProject: Bool { rows.contains { $0.found && $0.path != "CLAUDE.local.md" } }
    public var foundCount: Int { rows.filter(\.found).count }

    public static func inspect(_ folder: String, fileSystem fs: any ReadonlyFileSystem) -> ProjectInspection {
        func count(_ dir: String, suffix: String? = nil) -> Int {
            ((try? fs.contentsOfDirectory(joinPath(folder, dir))) ?? [])
                .filter { !$0.hasPrefix(".") && (suffix == nil || $0.hasSuffix(suffix ?? "")) }.count
        }
        func row(_ path: String, _ label: (Bool) -> String) -> Row {
            let found = fs.fileExists(joinPath(folder, path))
            return Row(path: path, label: label(found), found: found)
        }
        let skills = count(".claude/skills")
        let commands = count(".claude/commands", suffix: ".md")
        let agents = count(".claude/agents", suffix: ".md")
        let rules = count(".claude/rules")
        return ProjectInspection(
            folder: folder,
            rows: [
                row(".claude/settings.json") { $0 ? "Shared settings" : "No shared settings" },
                row(".claude/settings.local.json") { $0 ? "Your local settings" : "No local settings" },
                row(".mcp.json") { $0 ? "Project MCP servers" : "No project MCP servers" },
                row("CLAUDE.md") { $0 ? "Project memory" : "No CLAUDE.md" },
                row("CLAUDE.local.md") { $0 ? "Your local memory" : "No CLAUDE.local.md" },
                Row(path: ".claude/skills/", label: "\(skills) skills", found: skills > 0),
                Row(path: ".claude/commands/", label: "\(commands) commands", found: commands > 0),
                Row(path: ".claude/agents/", label: "\(agents) subagents", found: agents > 0),
                Row(path: ".claude/rules/", label: "\(rules) rules", found: rules > 0),
            ])
    }
}

/// What the Add plugin sheet shows for a source before anything is installed (PRD F09). Read-only.
public struct PluginSourceInspection: Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable { case localFolder, github, marketplace }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let name: String
        public let subtitle: String
        public let loadsInPlace: Bool
        public var id: String { name }
    }

    public let source: Source
    public let marketplaceName: String?
    public let entries: [Entry]
    /// Predicted ownership after install; only a local folder with relative sources is Personal.
    public let outcome: Ownership
    public let outcomeText: String
    public let problems: [String]

    /// Command lines Claw would run (shown for review; installing arrives in M5).
    public func commands(pluginName: String?, scope: SettingsScope, input: String) -> [String] {
        let plugin = pluginName ?? entries.first?.name ?? "<plugin>"
        let market = marketplaceName ?? "<marketplace>"
        var lines: [String] = []
        if source != .marketplace { lines.append("claude plugin marketplace add \(input)") }
        lines.append("claude plugin install \(plugin)@\(market) --scope \(scope.rawValue)")
        return lines
    }

    public static func localFolder(_ folder: String, fileSystem fs: any ReadonlyFileSystem) -> PluginSourceInspection {
        let manifest = joinPath(folder, ".claude-plugin", "marketplace.json")
        guard let data = try? fs.readFile(manifest) else {
            return PluginSourceInspection(
                source: .localFolder, marketplaceName: nil, entries: [], outcome: .market,
                outcomeText: "No .claude-plugin/marketplace.json in this folder.",
                problems: ["It needs .claude-plugin/marketplace.json at its root."])
        }
        guard let value = try? JSONValue.parse(data) else {
            return PluginSourceInspection(
                source: .localFolder, marketplaceName: nil, entries: [], outcome: .market,
                outcomeText: "marketplace.json is not valid JSON.", problems: ["Fix marketplace.json first."])
        }
        let entries = (value["plugins"]?.arrayValue ?? []).compactMap { plugin -> Entry? in
            guard let name = plugin["name"]?.stringValue, NameValidator.isValidName(name) else { return nil }
            let source = plugin["source"]?.stringValue
            let relative = source.map { $0.hasPrefix("./") || $0.hasPrefix("../") } ?? false
            let description = plugin["description"]?.stringValue ?? ""
            let location = relative ? "loads from this folder" : "copied to the plugin cache"
            return Entry(
                name: name, subtitle: description.isEmpty ? location : "\(description) · \(location)", loadsInPlace: relative)
        }
        let personal = entries.contains(where: \.loadsInPlace)
        return PluginSourceInspection(
            source: .localFolder, marketplaceName: value["name"]?.stringValue, entries: entries,
            outcome: personal ? .personal : .market,
            outcomeText: personal
                ? "Plugins with a relative source load from your folder, so they are Yours and editable."
                : "These plugins are copied to the cache, so they are Read-only.",
            problems: entries.isEmpty ? ["No valid plugins listed in marketplace.json."] : [])
    }

    /// `owner/repo` for a GitHub marketplace.
    public static func github(_ input: String) -> PluginSourceInspection {
        let parts = input.split(separator: "/", omittingEmptySubsequences: false)
        let valid = parts.count == 2 && parts.allSatisfy { NameValidator.isValidName(String($0)) }
        return PluginSourceInspection(
            source: .github, marketplaceName: valid ? String(parts[1]) : nil, entries: [], outcome: .market,
            outcomeText: "Installed from GitHub into the plugin cache: Read-only. Change it upstream.",
            problems: valid ? [] : ["Enter the repository as owner/repo."])
    }

    public static func marketplace(_ name: String, markets: [String: MarketplaceRecord]) -> PluginSourceInspection {
        guard let market = markets[name] else {
            return PluginSourceInspection(
                source: .marketplace, marketplaceName: nil, entries: [], outcome: .market,
                outcomeText: "Choose a registered marketplace.", problems: ["Unknown marketplace."])
        }
        let personal = market.source.isLocal
        return PluginSourceInspection(
            source: .marketplace, marketplaceName: name, entries: [], outcome: personal ? .personal : .market,
            outcomeText: personal
                ? "A local marketplace: plugins with a relative source stay editable."
                : "A \(market.source.rawValue) marketplace: installed plugins are Read-only.",
            problems: [])
    }
}
