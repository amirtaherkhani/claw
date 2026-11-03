import Foundation

public enum ClefVersion {
    public static let string = "0.1.0"
}

/// Read-only scan of plugins and skills (M1 scope so far; other concepts follow in M1.6 to M1.8).
public struct Scanner: Sendable {
    public let environment: ClaudeEnvironment
    public let target: ScanTarget
    private let fs: any ReadonlyFileSystem
    private let cli: ClaudeCLI?

    public init(
        environment: ClaudeEnvironment, target: ScanTarget = .mac,
        fileSystem: any ReadonlyFileSystem = LocalFileSystem(), cli: ClaudeCLI?
    ) {
        self.environment = environment
        self.target = target
        self.fs = fileSystem
        self.cli = cli
    }

    public func scan() async -> ScanResult {
        let started = Date()
        var problems: [Problem] = []
        var partial = false

        let settings = SettingsLoader(fileSystem: fs).loadAll(environment: environment)
        problems += settings.problems

        let marketReader = MarketplaceReader(fileSystem: fs)
        let (markets, marketProblems) = marketReader.readKnown(file: environment.knownMarketplacesFile)
        problems += marketProblems

        var version: String?
        var installed: [PluginRecord]?
        if let cli {
            do {
                version = try await cli.version()
                let list = try await cli.pluginList()
                installed = list.plugins
                problems += list.problems
            } catch {
                partial = true
                problems.append(
                    Problem(.warning, "Could not run `claude plugin list --json` (\(error)); plugins come from settings only"))
            }
        } else {
            partial = true
            problems.append(Problem(.note, "claude CLI not used; plugins come from settings only"))
        }

        var items: [Item] = []
        let plugins = pluginItems(installed: installed, layers: settings.layers, markets: markets, reader: marketReader)
        items += plugins.map(\.item)
        items += skillItems(layers: settings.layers, plugins: plugins)

        items.sort { ($0.concept.rawValue, $0.name, $0.id) < ($1.concept.rawValue, $1.name, $1.id) }
        return ScanResult(
            target: target, startedAt: started, finishedAt: Date(), partial: partial,
            claudeCodeVersion: version, items: items, problems: problems)
    }

    // MARK: Plugins

    struct PluginItem {
        let item: Item
        let record: PluginRecord?
    }

    /// Settings layers that decide a plugin's state for a project (`nil` = user scope only).
    private func pluginLayers(_ layers: [SettingsLayer], project: String?) -> [PluginLayer] {
        layers.filter { $0.projectPath == nil || $0.projectPath == project }
            .map { PluginLayer(source: PluginSource($0.scope), file: $0.file, enabledPlugins: $0.enabledPlugins) }
    }

    private func pluginItems(
        installed: [PluginRecord]?, layers: [SettingsLayer],
        markets: [String: MarketplaceRecord], reader: MarketplaceReader
    ) -> [PluginItem] {
        var result: [PluginItem] = []
        var seen = Set<String>()

        for record in installed ?? [] {
            seen.insert(record.id)
            var context = PluginClassifyContext(markets: markets)
            if let origin = record.origin, let market = markets[origin], market.source.isLocal {
                let folder = market.path.map { $0.hasSuffix(".json") ? parentDirectory($0) : $0 }
                context = PluginClassifyContext(
                    markets: markets,
                    entrySourceIsRelative: reader.entrySourceIsRelative(market: market, pluginName: record.name),
                    gitRemote: folder.flatMap { reader.gitRemote(folder: $0) }
                )
            }
            let classification = PluginClassifier.classify(record, context: context)
            let state = EffectivePluginState.resolve(
                record.id, layers: pluginLayers(layers, project: record.projectPath),
                fallback: record.enabled ?? false)
            var problems: [Problem] = []
            if let cliEnabled = record.enabled, cliEnabled != state.enabled {
                problems.append(
                    Problem(
                        .warning,
                        "claude reports enabled=\(cliEnabled) but settings resolve to \(state.enabled); the CLI value is shown"))
            }
            if !state.overridden.isEmpty {
                let names = state.overridden.map(\.source.rawValue).joined(separator: ", ")
                problems.append(Problem(.note, "Overridden by a higher scope; lower scopes (\(names)) disagree"))
            }
            result.append(
                PluginItem(
                    item: makePluginItem(
                        record: record, classification: classification,
                        enabled: record.enabled ?? state.enabled, state: state, problems: problems
                    ), record: record))
        }

        // P8: declared in settings but not installed (or no CLI to tell).
        var declared: [String: SettingsLayer] = [:]
        for layer in layers {
            for id in layer.enabledPlugins.keys where declared[id] == nil { declared[id] = layer }
        }
        for id in declared.keys.sorted() where !seen.contains(id) && NameValidator.isValidPluginId(id) {
            let record = PluginRecord(id: id, installPath: "")
            let state = EffectivePluginState.resolve(id, layers: pluginLayers(layers, project: declared[id]?.projectPath))
            let classification: Classification
            var problems: [Problem] = []
            if installed != nil {
                classification = Classification(
                    ownership: .orphan, rule: "P8",
                    evidence: ["declared in \(declared[id]?.file ?? "settings") but not installed"])
                problems.append(Problem(.warning, "Declared in settings but not installed", file: declared[id]?.file))
            } else {
                classification = PluginClassifier.classify(record, context: PluginClassifyContext(markets: markets))
                problems.append(Problem(.note, "Install state unknown without the claude CLI"))
            }
            result.append(
                PluginItem(
                    item: makePluginItem(
                        record: record, classification: classification,
                        enabled: state.enabled, state: state, problems: problems),
                    record: nil))
        }
        return result
    }

    private func makePluginItem(
        record: PluginRecord, classification: Classification, enabled: Bool,
        state: EffectiveState, problems: [Problem]
    ) -> Item {
        let scope: ItemScope =
            switch record.scope {
            case "project": .project
            case "local": .local
            case "managed": .managed
            case "synced": .synced
            default: .user
            }
        return Item(
            concept: .plugins,
            key: record.projectPath.map { "\(record.id)@\($0)" } ?? record.id,
            name: record.name,
            description: record.version.map { "\(record.id) v\($0)" } ?? record.id,
            scope: scope,
            projectPath: record.projectPath,
            classification: classification,
            location: record.readFromFolder ?? record.installPath,
            enabled: enabled,
            enabledBy: state.decidedBy?.rawValue,
            enabledByFile: state.file,
            control: ControlRef(mechanism: .enabledPlugins, key: "enabledPlugins[\"\(record.id)\"]", status: .verified),
            capabilities: Capabilities.forOwnership(classification.ownership, isPlugin: true),
            problems: problems
        )
    }

    // MARK: Skills

    /// `skillOverrides` precedence: managed > local > project > user [V `settings`].
    private func skillOverride(_ name: String, layers: [SettingsLayer], project: String?) -> (
        value: String, layer: SettingsLayer
    )? {
        for scope in SettingsScope.allCases {
            for layer in layers where layer.scope == scope && (layer.projectPath == nil || layer.projectPath == project) {
                if let value = layer.skillOverrides[name] { return (value, layer) }
            }
        }
        return nil
    }

    private func skillItems(layers: [SettingsLayer], plugins: [PluginItem]) -> [Item] {
        let reader = SkillReader(fileSystem: fs)
        var items: [Item] = []

        func personal(_ skill: SkillRecord, scope: ItemScope, project: String?, rule: String) -> Item {
            let override = skillOverride(skill.name, layers: layers, project: project)
            let classification = Classification(ownership: .personal, rule: rule, evidence: ["file at \(skill.file)"])
            return Item(
                concept: .skills, key: project.map { "\($0):\(skill.name)" } ?? skill.name,
                name: skill.name, description: skill.description, scope: scope, projectPath: project,
                classification: classification, location: skill.directory,
                enabled: override?.value != "off",
                enabledBy: override?.layer.scope.rawValue, enabledByFile: override?.layer.file,
                control: ControlRef(mechanism: .skillOverrides, key: "skillOverrides[\"\(skill.name)\"]", status: .verified),
                capabilities: Capabilities.forOwnership(.personal, isPlugin: false),
                problems: skill.problems
            )
        }

        if target.kind == .mac {
            for skill in reader.readSkills(in: environment.userSkillsDir, skipping: ["synced"]) {
                items.append(personal(skill, scope: .user, project: nil, rule: "L1"))
            }
            for skill in reader.readSkills(in: environment.syncedSkillsDir) {
                let classification = Classification(
                    ownership: .synced, rule: "L3",
                    evidence: ["under \(environment.syncedSkillsDir)"])
                items.append(
                    Item(
                        concept: .skills, key: "synced:\(skill.name)", name: skill.name, description: skill.description,
                        scope: .synced, classification: classification, location: skill.directory, enabled: true,
                        control: ControlRef(mechanism: .syncSetting, key: "syncClaudeAiSkills", status: .verified),
                        capabilities: Capabilities.forOwnership(.synced, isPlugin: false), problems: skill.problems
                    ))
            }
        }
        for project in environment.projects {
            for skill in reader.readSkills(in: environment.projectSkillsDir(project)) {
                items.append(personal(skill, scope: .project, project: project, rule: "L2"))
            }
        }

        // Plugin skills follow the plugin; skillOverrides does not apply to them [V `skills`].
        for plugin in plugins {
            guard let record = plugin.record else { continue }
            let root = record.readFromFolder ?? record.installPath
            for skill in reader.readSkills(in: joinPath(root, "skills")) {
                let classification = Classification(ownership: .plugin, rule: "L4", evidence: ["provided by \(record.id)"])
                items.append(
                    Item(
                        concept: .skills, key: "\(record.id):\(skill.name)", name: "\(record.name):\(skill.name)",
                        description: skill.description, scope: .plugin, projectPath: record.projectPath,
                        classification: classification, location: skill.directory, enabled: plugin.item.enabled,
                        enabledBy: plugin.item.enabledBy, enabledByFile: plugin.item.enabledByFile,
                        control: ControlRef(mechanism: .parentPlugin, key: "enabledPlugins[\"\(record.id)\"]", status: .verified),
                        capabilities: Capabilities.forOwnership(.plugin, isPlugin: false),
                        providedBy: record.id, problems: skill.problems
                    ))
            }
        }
        return items
    }
}

private func parentDirectory(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().path
}
