import Foundation

/// Commands, subagents, rules, MCP servers and hooks (M1.6 to M1.8).
extension Scanner {
    struct ConceptScan {
        var items: [Item] = []
        var problems: [Problem] = []
    }

    typealias InstalledPlugin = (record: PluginRecord, item: Item)

    func conceptItems(layers: [SettingsLayer], plugins: [PluginItem]) -> ConceptScan {
        var scan = ConceptScan()
        let includeUser = target.kind == .mac
        let installed: [InstalledPlugin] = plugins.compactMap { plugin in plugin.record.map { ($0, plugin.item) } }

        commandItems(layers: layers, installed: installed, includeUser: includeUser, into: &scan)
        agentItems(layers: layers, installed: installed, includeUser: includeUser, into: &scan)
        ruleItems(layers: layers, includeUser: includeUser, into: &scan)
        mcpItems(layers: layers, installed: installed, includeUser: includeUser, into: &scan)
        hookItems(layers: layers, installed: installed, into: &scan)
        return scan
    }

    // MARK: Helpers

    private func applicable(_ layers: [SettingsLayer], project: String?) -> [SettingsLayer] {
        layers.filter { $0.projectPath == nil || $0.projectPath == project }
    }

    /// Value of a top-level key after precedence (managed > local > project > user).
    private func effectiveValue(_ key: String, layers: [SettingsLayer], project: String?) -> JSONValue? {
        let relevant = applicable(layers, project: project)
        for scope in SettingsScope.allCases {
            for layer in relevant where layer.scope == scope {
                if let value = layer.values[key] { return value }
            }
        }
        return nil
    }

    /// Arrays that merge across layers (`permissions.deny`, `claudeMdExcludes`) [V `settings`].
    private func mergedStrings(_ path: [String], layers: [SettingsLayer], project: String?) -> [String] {
        applicable(layers, project: project).flatMap { layer -> [String] in
            var value: JSONValue? = .object(layer.values)
            for key in path { value = value?[key] }
            return value?.arrayValue?.compactMap(\.stringValue) ?? []
        }
    }

    private func pluginRoot(_ record: PluginRecord) -> String { record.readFromFolder ?? record.installPath }

    private func personal(_ rule: String, _ file: String) -> Classification {
        Classification(ownership: .personal, rule: rule, evidence: ["file at \(file)"])
    }

    private func fromPlugin(_ record: PluginRecord) -> Classification {
        Classification(ownership: .plugin, rule: "L4", evidence: ["provided by \(record.id)"])
    }

    private func parentControl(_ id: String) -> ControlRef {
        ControlRef(mechanism: .parentPlugin, key: "enabledPlugins[\"\(id)\"]", status: .verified)
    }

    private func pluginEntryItem(
        _ concept: Concept, _ entry: MarkdownEntry, name: String, plugin: InstalledPlugin
    ) -> Item {
        Item(
            concept: concept, key: "\(plugin.record.id):\(entry.name)", name: name,
            description: entry.description, scope: .plugin, projectPath: plugin.record.projectPath,
            classification: fromPlugin(plugin.record), location: entry.file, enabled: plugin.item.enabled,
            enabledBy: plugin.item.enabledBy, enabledByFile: plugin.item.enabledByFile,
            control: parentControl(plugin.record.id), capabilities: Capabilities.forOwnership(.plugin, isPlugin: false),
            providedBy: plugin.record.id, problems: entry.problems)
    }

    // MARK: Commands

    private func commandItems(
        layers: [SettingsLayer], installed: [InstalledPlugin], includeUser: Bool, into scan: inout ConceptScan
    ) {
        let reader = MarkdownReader(fileSystem: fs)
        func add(_ entry: MarkdownEntry, scope: ItemScope, project: String?, rule: String) {
            // Whether `skillOverrides` applies to command files is unverified (spike S2).
            let override = skillOverride(entry.name, layers: layers, project: project)
            scan.items.append(
                Item(
                    concept: .commands, key: (project.map { "\($0):" } ?? "") + entry.name, name: "/" + entry.name,
                    description: entry.description, scope: scope, projectPath: project,
                    classification: personal(rule, entry.file), location: entry.file,
                    enabled: override?.value != "off", enabledBy: override?.layer.scope.rawValue,
                    enabledByFile: override?.layer.file,
                    control: ControlRef(
                        mechanism: .skillOverrides, key: "skillOverrides[\"\(entry.name)\"]", status: .unknown),
                    capabilities: Capabilities.forOwnership(.personal, isPlugin: false), problems: entry.problems))
        }
        if includeUser {
            for entry in reader.read(in: joinPath(environment.configDir, "commands"), naming: .path) {
                add(entry, scope: .user, project: nil, rule: "L1")
            }
        }
        for project in environment.projects {
            for entry in reader.read(in: joinPath(project, ".claude", "commands"), naming: .path) {
                add(entry, scope: .project, project: project, rule: "L2")
            }
        }
        for plugin in installed {
            for entry in reader.read(in: joinPath(pluginRoot(plugin.record), "commands"), naming: .path) {
                scan.items.append(
                    pluginEntryItem(.commands, entry, name: "/\(plugin.record.name):\(entry.name)", plugin: plugin))
            }
        }
    }

    // MARK: Subagents

    private func agentItems(
        layers: [SettingsLayer], installed: [InstalledPlugin], includeUser: Bool, into scan: inout ConceptScan
    ) {
        let reader = MarkdownReader(fileSystem: fs)
        func add(_ entry: MarkdownEntry, scope: ItemScope, project: String?, rule: String) {
            let deny = Set(mergedStrings(["permissions", "deny"], layers: layers, project: project))
            let denied = deny.contains("Agent(\(entry.name))") || deny.contains("Task(\(entry.name))")
            scan.items.append(
                Item(
                    concept: .agents, key: (project.map { "\($0):" } ?? "") + entry.name, name: entry.name,
                    description: entry.description, scope: scope, projectPath: project,
                    classification: personal(rule, entry.file), location: entry.file, enabled: !denied,
                    enabledBy: denied ? "permissions.deny" : nil,
                    control: ControlRef(
                        mechanism: .permissionsDeny, key: "permissions.deny: Agent(\(entry.name))", status: .verified),
                    capabilities: Capabilities.forOwnership(.personal, isPlugin: false), problems: entry.problems))
        }
        if includeUser {
            for entry in reader.read(in: joinPath(environment.configDir, "agents"), naming: .frontmatterThenPath) {
                add(entry, scope: .user, project: nil, rule: "L1")
            }
        }
        for project in environment.projects {
            for entry in reader.read(in: joinPath(project, ".claude", "agents"), naming: .frontmatterThenPath) {
                add(entry, scope: .project, project: project, rule: "L2")
            }
        }
        // Deny syntax for plugin subagents is unverified (spike S6): they follow the plugin.
        for plugin in installed {
            for entry in reader.read(in: joinPath(pluginRoot(plugin.record), "agents"), naming: .frontmatterThenPath) {
                scan.items.append(
                    pluginEntryItem(.agents, entry, name: "\(plugin.record.name):\(entry.name)", plugin: plugin))
            }
        }
    }

    // MARK: Rules

    private func ruleItems(layers: [SettingsLayer], includeUser: Bool, into scan: inout ConceptScan) {
        for file in RuleReader(fileSystem: fs).ruleFiles(environment: environment, includeUser: includeUser) {
            let isManaged = file.scope == .managed
            let excludes = mergedStrings(["claudeMdExcludes"], layers: layers, project: file.projectPath)
            let resolved = fs.resolvingSymlinks(file.path)
            let match = excludes.first { Glob.matches($0, file.path) || Glob.matches($0, resolved) }
            let excluded = !isManaged && match != nil
            let display: String
            if let project = file.projectPath, file.path.hasPrefix(project + "/") {
                display = String(file.path.dropFirst(project.count + 1))
            } else if file.path.hasPrefix(environment.home + "/") {
                display = "~/" + file.path.dropFirst(environment.home.count + 1)
            } else {
                display = file.path
            }
            let classification =
                isManaged
                ? Classification(ownership: .managed, rule: "L5", evidence: ["under \(environment.managedDir)"])
                : personal(file.scope == .user ? "L1" : "L2", file.path)
            let control =
                isManaged
                ? ControlRef(mechanism: .none, key: "managed CLAUDE.md cannot be excluded", status: .verified)
                : ControlRef(mechanism: .claudeMdExcludes, key: "claudeMdExcludes: \(file.path)", status: .verified)
            scan.items.append(
                Item(
                    concept: .rules, key: file.path, name: display,
                    description: file.scope.rawValue.capitalized + " memory",
                    scope: file.scope, projectPath: file.projectPath, classification: classification,
                    location: file.path, enabled: !excluded, enabledBy: excluded ? "claudeMdExcludes" : nil,
                    control: control,
                    capabilities: Capabilities.forOwnership(classification.ownership, isPlugin: false),
                    problems: excluded ? [Problem(.note, "Excluded by pattern \(match ?? "")")] : []))
        }
    }

    // MARK: MCP servers

    private func mcpItem(
        _ server: MCPServerRecord, enabled: Bool, enabledBy: String?, control: ControlRef,
        classification: Classification, providedBy: PluginRecord? = nil, problems: [Problem] = []
    ) -> Item {
        Item(
            concept: .mcp, key: "\(server.projectPath ?? "~"):\(providedBy?.id ?? ""):\(server.name)",
            name: providedBy.map { "plugin:\($0.name):\(server.name)" } ?? server.name,
            description: "\(server.transport) · \(server.summary)", scope: server.scope,
            projectPath: server.projectPath, classification: classification, location: server.file,
            enabled: enabled, enabledBy: enabledBy, control: control,
            capabilities: Capabilities.forOwnership(classification.ownership, isPlugin: false),
            providedBy: providedBy?.id, problems: problems)
    }

    private func mcpItems(
        layers: [SettingsLayer], installed: [InstalledPlugin], includeUser: Bool, into scan: inout ConceptScan
    ) {
        let reader = MCPReader(fileSystem: fs)
        let claudeJsonFile = environment.claudeJsonFile
        let claudeJson = reader.readClaudeJson(file: claudeJsonFile, projects: environment.projects)
        scan.problems += claudeJson.problems
        let perProject = ControlRef(
            mechanism: .disabledMcpServers, key: "projects[<path>].disabledMcpServers", status: .unknown)

        // User scope: off in a project only through that project's `disabledMcpServers`.
        if includeUser {
            for server in claudeJson.user {
                let offIn = claudeJson.disabledByProject.filter { $0.value.contains(server.name) }.keys.sorted()
                scan.items.append(
                    mcpItem(
                        server, enabled: true, enabledBy: nil, control: perProject,
                        classification: personal("L1", claudeJsonFile),
                        problems: offIn.isEmpty ? [] : [Problem(.note, "Disabled in: \(offIn.joined(separator: ", "))")]))
            }
        }
        for server in claudeJson.local {
            let off = claudeJson.disabledByProject[server.projectPath ?? ""]?.contains(server.name) ?? false
            scan.items.append(
                mcpItem(
                    server, enabled: !off, enabledBy: off ? "disabledMcpServers" : nil, control: perProject,
                    classification: personal("L2", claudeJsonFile)))
        }

        // Project `.mcp.json`: needs approval unless enabled by name or by `enableAllProjectMcpServers` [V `settings`].
        for project in environment.projects {
            let file = joinPath(project, ".mcp.json")
            let (servers, problems) = reader.readMcpJson(file: file, scope: .project, projectPath: project)
            scan.problems += problems
            let disabled = Set(mergedStrings(["disabledMcpjsonServers"], layers: layers, project: project))
            let enabledByName = Set(mergedStrings(["enabledMcpjsonServers"], layers: layers, project: project))
            let enableAll = effectiveValue("enableAllProjectMcpServers", layers: layers, project: project)?.boolValue == true
            for server in servers {
                let off = disabled.contains(server.name)
                let approved = enableAll || enabledByName.contains(server.name)
                let notes =
                    (!off && !approved)
                    ? [Problem(.note, "Not approved in settings; Claude Code asks before first use")] : []
                scan.items.append(
                    mcpItem(
                        server, enabled: !off && approved, enabledBy: off ? "disabledMcpjsonServers" : nil,
                        control: ControlRef(
                            mechanism: .disabledMcpjsonServers, key: "disabledMcpjsonServers: \(server.name)",
                            status: .unknown),
                        classification: personal("L2", file), problems: notes))
            }
        }

        for plugin in installed {
            let (servers, problems) = reader.readMcpJson(
                file: joinPath(pluginRoot(plugin.record), ".mcp.json"), scope: .plugin,
                projectPath: plugin.record.projectPath)
            scan.problems += problems
            for server in servers {
                scan.items.append(
                    mcpItem(
                        server, enabled: plugin.item.enabled, enabledBy: plugin.item.enabledBy,
                        control: parentControl(plugin.record.id), classification: fromPlugin(plugin.record),
                        providedBy: plugin.record))
            }
        }
    }

    // MARK: Hooks

    private func hookItem(
        _ hook: HookRecord, scope: ItemScope, project: String?, classification: Classification,
        enabled: Bool, enabledBy: String?, providedBy: String? = nil
    ) -> Item {
        let matcher = hook.matcher.map { $0.isEmpty ? "" : " [\($0)]" } ?? ""
        let problems =
            hook.isGuard
            ? [Problem(.note, "Guard hook: it can block or approve tool use; removing it changes safety behaviour")] : []
        let stash = classification.ownership == .personal
        let control: ControlRef
        if stash {
            control = ControlRef(mechanism: .hookStash, key: "remove and stash (no per-hook switch)", status: .verified)
        } else if let providedBy {
            control = parentControl(providedBy)
        } else {
            control = ControlRef(mechanism: .none, key: "managed policy", status: .verified)
        }
        return Item(
            concept: .hooks, key: "\(hook.file)#\(hook.event)/\(hook.groupIndex)/\(hook.handlerIndex)",
            name: "\(hook.event)\(matcher) · \(hook.summary)", description: "\(hook.handlerType) hook",
            scope: scope, projectPath: project, classification: classification,
            location: "\(hook.file) › hooks.\(hook.event)[\(hook.groupIndex)].hooks[\(hook.handlerIndex)]",
            enabled: enabled, enabledBy: enabledBy, control: control,
            capabilities: stash
                ? Capabilities(edit: true, toggle: true, remove: true, removeLabel: "Remove entry", reason: nil)
                : Capabilities.forOwnership(classification.ownership, isPlugin: false),
            providedBy: providedBy, problems: problems)
    }

    private func hookItems(layers: [SettingsLayer], installed: [InstalledPlugin], into scan: inout ConceptScan) {
        // `disableAllHooks`: value after precedence; managed hooks only by the managed value.
        // `allowManagedHooksOnly` (managed) blocks user, project, local and plugin hooks [V `hooks`].
        let managed = layers.first { $0.scope == .managed }
        let managedOnly = managed?.values["allowManagedHooksOnly"]?.boolValue == true
        let managedDisableAll = managed?.values["disableAllHooks"]?.boolValue == true

        for layer in layers {
            let (hooks, problems) = HookReader.parse(layer.values["hooks"], file: layer.file)
            scan.problems += problems
            let isManaged = layer.scope == .managed
            let disableAll =
                isManaged
                ? managedDisableAll
                : effectiveValue("disableAllHooks", layers: layers, project: layer.projectPath)?.boolValue == true
            let blocked = !isManaged && managedOnly
            let classification =
                isManaged
                ? Classification(ownership: .managed, rule: "L5", evidence: ["managed settings"])
                : personal(layer.scope == .user ? "L1" : "L2", layer.file)
            for hook in hooks {
                scan.items.append(
                    hookItem(
                        hook, scope: ItemScope(rawValue: layer.scope.rawValue) ?? .user, project: layer.projectPath,
                        classification: classification, enabled: !disableAll && !blocked,
                        enabledBy: blocked ? "allowManagedHooksOnly" : (disableAll ? "disableAllHooks" : nil)))
            }
        }

        for plugin in installed {
            let file = joinPath(pluginRoot(plugin.record), "hooks", "hooks.json")
            guard let data = try? fs.readFile(file) else { continue }
            guard let value = try? JSONValue.parse(data) else {
                scan.problems.append(Problem(.error, "Plugin hooks file is not valid JSON", file: file))
                continue
            }
            let (hooks, problems) = HookReader.parse(value["hooks"], file: file)
            scan.problems += problems
            let disableAll =
                effectiveValue("disableAllHooks", layers: layers, project: plugin.record.projectPath)?.boolValue == true
            for hook in hooks {
                scan.items.append(
                    hookItem(
                        hook, scope: .plugin, project: plugin.record.projectPath,
                        classification: fromPlugin(plugin.record),
                        enabled: plugin.item.enabled && !disableAll && !managedOnly,
                        enabledBy: managedOnly
                            ? "allowManagedHooksOnly" : (disableAll ? "disableAllHooks" : plugin.item.enabledBy),
                        providedBy: plugin.record.id))
            }
        }
    }
}
