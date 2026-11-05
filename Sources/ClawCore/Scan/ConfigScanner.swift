import Foundation

public enum ClawVersion {
    public static let string = "0.1.0"
}

public struct ScanProgress: Sendable, Equatable {
    public enum Step: String, Sendable, CaseIterable {
        case settings, claudeCLI, plugins, skills, otherConcepts, done

        public var label: String {
            switch self {
            case .settings: "Reading settings and marketplaces"
            case .claudeCLI: "Asking claude for installed plugins"
            case .plugins: "Classifying plugins"
            case .skills: "Reading skills"
            case .otherConcepts: "Reading commands, rules, subagents, MCP servers and hooks"
            case .done: "Done"
            }
        }

        /// 0...1 for a progress bar.
        public var fraction: Double {
            Double(Self.allCases.firstIndex(of: self) ?? 0) / Double(Self.allCases.count - 1)
        }
    }

    public let step: Step
    public let itemCount: Int
    /// The path of a disk call that has not returned for a while; macOS may be holding it for a privacy
    /// prompt (`docs/spikes.md` F9).
    public let waitingOn: String?

    public init(step: Step, itemCount: Int, waitingOn: String? = nil) {
        self.step = step
        self.itemCount = itemCount
        self.waitingOn = waitingOn
    }
}

/// Read-only scan of all seven concepts. Never writes and never executes scanned content.
public struct ConfigScanner: Sendable {
    public let environment: ClaudeEnvironment
    public let target: ScanTarget
    private(set) var fs: any ReadonlyFileSystem
    private let cli: ClaudeCLI?
    private let stallThreshold: Duration

    /// - Parameter stallThreshold: how long one disk call may run before progress reports `waitingOn`.
    public init(
        environment: ClaudeEnvironment, target: ScanTarget = .mac,
        fileSystem: any ReadonlyFileSystem = LocalFileSystem(), cli: ClaudeCLI?,
        stallThreshold: Duration = .seconds(3)
    ) {
        self.environment = environment
        self.target = target
        self.fs = fileSystem
        self.cli = cli
        self.stallThreshold = stallThreshold
    }

    /// Runs the scan. Reports progress after each step, and again when a disk call stalls or recovers.
    /// When the surrounding task is cancelled (Stop), it returns the finished steps with `partial == true`,
    /// even if a disk call is blocked.
    public func scan(progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanResult {
        let started = Date()
        var problems: [Problem] = []
        var partial = false
        var items: [Item] = []
        var version: String?
        let disk = StoppableFileSystem(fs)
        let contained = ContainedFileSystem(disk, environment: environment)

        func finish() -> ScanResult {
            problems += contained.problems
            items.sort { ($0.concept.rawValue, $0.name, $0.id) < ($1.concept.rawValue, $1.name, $1.id) }
            progress?(ScanProgress(step: .done, itemCount: items.count))
            return ScanResult(
                target: target, startedAt: started, finishedAt: Date(), partial: partial,
                claudeCodeVersion: version, items: items, problems: problems)
        }
        func stop() -> ScanResult {
            partial = true
            problems.append(Problem(.note, "Scan stopped; the results are incomplete"))
            return finish()
        }

        let scanner = reading(through: contained)
        /// Runs one step's disk work off the concurrency pool. `nil` means the scan was stopped.
        func read<T: Sendable>(_ step: ScanProgress.Step, _ work: @escaping @Sendable () -> T) async -> T? {
            let update = ScanProgress(step: step, itemCount: items.count)
            progress?(update)
            let watcher = watch(disk, update: update, progress: progress)
            let value = await disk.run(work)
            watcher.cancel()
            await watcher.value  // No stall report may arrive after the next step's progress.
            return value
        }

        let loaded = await read(.settings) {
            let settings = SettingsLoader(fileSystem: contained).loadAll(environment: scanner.environment)
            let known = MarketplaceReader(fileSystem: contained).readKnown(file: scanner.environment.knownMarketplacesFile)
            return (settings: settings, markets: known.0, marketProblems: known.1)
        }
        guard let loaded else { return stop() }
        let (settings, markets) = (loaded.settings, loaded.markets)
        problems += settings.problems + loaded.marketProblems
        if Task.isCancelled { return stop() }

        progress?(ScanProgress(step: .claudeCLI, itemCount: 0))
        var installed: [PluginRecord]?
        if let cli {
            do {
                version = try await cli.version()
                let list = try await cli.pluginList()
                installed = list.plugins
                problems += list.problems
            } catch {
                partial = true
                if !Task.isCancelled {
                    problems.append(
                        Problem(.warning, "Could not run `claude plugin list --json` (\(error)); plugins come from settings only")
                    )
                }
            }
        } else {
            partial = true
            problems.append(Problem(.note, "claude CLI not used; plugins come from settings only"))
        }
        if Task.isCancelled { return stop() }

        let records = installed
        let found = await read(.plugins) {
            contained.addRoots(
                markets.values.compactMap(\.path).map { $0.hasSuffix(".json") ? parentDirectory($0) : $0 }
                    + (records ?? []).flatMap { [$0.installPath, $0.readFromFolder].compactMap { $0 } })
            return scanner.pluginItems(
                installed: records, layers: settings.layers, markets: markets, reader: MarketplaceReader(fileSystem: contained))
        }
        guard let found else { return stop() }
        let plugins = inTarget(found)
        items += plugins.map(\.item)
        if Task.isCancelled { return stop() }

        let skills = await read(.skills) { scanner.skillItems(layers: settings.layers, plugins: plugins) }
        guard let skills else { return stop() }
        items += skills
        if Task.isCancelled { return stop() }

        let concepts = await read(.otherConcepts) { scanner.conceptItems(layers: settings.layers, plugins: plugins) }
        guard let concepts else { return stop() }
        items += concepts.items
        problems += concepts.problems
        return finish()
    }

    /// Last-modified dates of the items' files, keyed by file. Empty when the task is cancelled.
    public func modificationDates(for items: [Item]) async -> [String: Date] {
        let disk = StoppableFileSystem(fs)
        let dates = await disk.run {
            var dates: [String: Date] = [:]
            for item in items {
                let file = ItemPresentation.file(item)
                if dates[file] == nil, let date = disk.modificationDate(file) { dates[file] = date }
            }
            return dates
        }
        return dates ?? [:]
    }

    private func reading(through contained: ContainedFileSystem) -> ConfigScanner {
        var copy = self
        copy.fs = contained
        return copy
    }

    /// Repeats `update` with `waitingOn` set while a disk call stalls, and clears it when the call returns.
    private func watch(
        _ disk: StoppableFileSystem, update: ScanProgress, progress: (@Sendable (ScanProgress) -> Void)?
    ) -> Task<Void, Never> {
        let threshold = stallThreshold
        return Task {
            var reported: String?
            while (try? await Task.sleep(for: .milliseconds(250))) != nil {
                let waiting = disk.path(runningFor: threshold)
                guard waiting != reported else { continue }
                reported = waiting
                progress?(ScanProgress(step: update.step, itemCount: update.itemCount, waitingOn: waiting))
            }
        }
    }

    // MARK: Plugins

    struct PluginItem {
        let item: Item
        let record: PluginRecord?
    }

    /// A folder scan keeps only that folder's plugins, and so nothing they provide (FR-F02-2).
    private func inTarget(_ plugins: [PluginItem]) -> [PluginItem] {
        guard target.kind == .folder else { return plugins }
        return plugins.filter { $0.item.projectPath == target.path }
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
                        enabled: state.enabled, state: state, problems: problems, declaredIn: declared[id]?.projectPath),
                    record: nil))
        }
        return result
    }

    /// - Parameter declaredIn: the project whose settings name a plugin that has no install record.
    private func makePluginItem(
        record: PluginRecord, classification: Classification, enabled: Bool,
        state: EffectiveState, problems: [Problem], declaredIn: String? = nil
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
            projectPath: record.projectPath ?? declaredIn,
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
    func skillOverride(_ name: String, layers: [SettingsLayer], project: String?) -> (
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
            guard !root.isEmpty else { continue }  // Listed by the CLI, but it has no files to read.
            let skills = reader.readSkills(in: joinPath(root, "skills"))
            for skill in skills.isEmpty ? reader.readRootSkill(in: root, name: record.name) : skills {
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
