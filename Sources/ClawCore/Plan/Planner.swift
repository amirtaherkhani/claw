import Foundation

/// When a change reaches a running session [V S4, TECHNICAL-DESIGN section 3.4].
public enum PlanEffect: String, Sendable, Codable {
    case live, reloadPlugins, afterClear, newSession
}

public struct FileEdit: Sendable, Equatable {
    public let file: String
    /// `nil` when the file does not exist yet.
    public let before: Data?
    public let after: Data
    public let reason: String
}

/// One `claude` call, as an argument vector: no shell ever sees it (`NFR-SEC-2`).
public struct CliStep: Sendable, Equatable {
    public let argv: [String]
    /// Project and local scopes act on the folder the CLI runs in.
    public let workingDirectory: String?
}

/// What a change does to the hook stash.
public enum StashAction: Sendable, Equatable {
    case put(HookStashEntry)
    case take(String)
}

/// What `claude plugin list --json` must say afterwards. `enabled` is `nil` for an uninstall.
public struct PluginCheck: Sendable, Equatable {
    public let id: String
    public let enabled: Bool?
    public let scope: String?
}

public struct PlannedChange: Sendable, Equatable {
    public let itemId: String
    /// `nil` for a removal.
    public var enabled: Bool?
    /// Empty when the file already says what was asked.
    public let edits: [FileEdit]
    /// Files and folders that move to the backup.
    public var moves: [String] = []
    public var cli: [CliStep] = []
    /// Files the CLI step rewrites, which the backup has to keep first.
    public var cliTouches: [String] = []
    public let effect: PlanEffect
    public let warnings: [String]
    public var stash: StashAction?
    public var pluginCheck: PluginCheck?
}

public struct PlanError: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

/// Turns a queued change into exact file edits. It writes nothing (TECHNICAL-DESIGN section 9.1); a control
/// still marked `unknown` is refused, so no unverified key reaches Apply.
public struct Planner: Sendable {
    private let environment: ClaudeEnvironment
    private let fileSystem: any ReadonlyFileSystem

    public init(environment: ClaudeEnvironment, fileSystem: any ReadonlyFileSystem) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    public func setEnabled(
        _ item: Item, enabled: Bool, writeScope: WriteScope?, activeProject: String?, date: Date = Date()
    ) throws -> PlannedChange {
        var pending: [String: Data] = [:]
        return try plan(
            item, enabled: enabled, writeScope: writeScope, activeProject: activeProject, date: date, pending: &pending)
    }

    /// Plans in order; a later change to a file builds on the earlier one.
    public func setEnabled(
        _ changes: [(item: Item, enabled: Bool)], writeScope: WriteScope?, activeProject: String?, date: Date = Date()
    ) throws -> [PlannedChange] {
        var pending: [String: Data] = [:]
        return try changes.map {
            try plan(
                $0.item, enabled: $0.enabled, writeScope: writeScope, activeProject: activeProject, date: date,
                pending: &pending)
        }
    }

    /// Puts a stashed hook back: in its place when it can, in a group with its matcher otherwise, or in a new group.
    /// An identical handler already there means nothing to write, and the stash is still taken.
    public func restore(_ entry: HookStashEntry) throws -> PlannedChange {
        let base = try read(entry.sourceFile)
        let text = base ?? Data("{}\n".utf8)
        let after: Data
        do {
            after = try Self.restored(entry, in: text)
        } catch let error as JSONEditError {
            throw PlanError(reason: "\(entry.sourceFile): \(error.reason)")
        }
        let edits =
            after == text
            ? [] : [FileEdit(file: entry.sourceFile, before: base, after: after, reason: "Restore a \(entry.event) hook")]
        return PlannedChange(
            itemId: entry.id, enabled: true, edits: edits, effect: .live, warnings: [], stash: .take(entry.id))
    }

    private static func restored(_ entry: HookStashEntry, in data: Data) throws -> Data {
        let event: [JSONPathComponent] = ["hooks", .key(entry.event)]
        let groups = try value(at: event, in: data)?.arrayValue ?? []
        let matches = groups.indices.filter { groups[$0]["matcher"]?.stringValue == entry.matcher }
        if matches.contains(where: { groups[$0]["hooks"]?.arrayValue?.contains(entry.handler) == true }) { return data }

        let wanted = entry.position.groupIndex
        if let group = matches.contains(wanted) ? wanted : matches.first {
            let count = groups[group]["hooks"]?.arrayValue?.count ?? 0
            return try JSONEdit.insert(
                data, arrayAt: event + [.index(group), "hooks"],
                index: group == wanted ? min(entry.position.handlerIndex, count) : count, value: entry.handler,
                raw: Data(entry.handlerText.utf8))
        }
        var group: [String: JSONValue] = ["hooks": .array([entry.handler])]
        if let matcher = entry.matcher { group["matcher"] = .string(matcher) }
        return try JSONEdit.insert(
            data, arrayAt: event, index: groups.isEmpty ? nil : min(wanted, groups.count), value: .object(group),
            raw: entry.groupText.map { Data($0.utf8) })
    }

    /// Plans one removal. `keepData` decides what uninstalling does to a plugin's data folder.
    public func remove(_ item: Item, keepData: Bool = true) throws -> PlannedChange {
        var pending: [String: Data] = [:]
        return try planRemoval(item, keepData: keepData, pending: &pending)
    }

    /// Plans removals on top of each other. Hooks go last-first, so an earlier removal cannot shift a later index.
    public func remove(_ items: [Item], keepData: Bool = true) throws -> [PlannedChange] {
        var pending: [String: Data] = [:]
        let ordered = items.sorted {
            (Self.hookPosition($0)?.order ?? []).lexicographicallyPrecedes(Self.hookPosition($1)?.order ?? [])
        }
        return try ordered.reversed().map { try planRemoval($0, keepData: keepData, pending: &pending) }
    }

    private func planRemoval(_ item: Item, keepData: Bool, pending: inout [String: Data]) throws -> PlannedChange {
        guard item.capabilities.remove else {
            throw PlanError(reason: item.capabilities.reason ?? "\(item.name) cannot be removed")
        }
        switch item.concept {
        case .plugins: return try removePlugin(item, keepData: keepData, pending: &pending)
        case .mcp: return try removeServer(item, pending: &pending)
        case .hooks: return try removeHook(item, pending: &pending)
        case .skills, .commands, .agents, .rules:
            let effect: PlanEffect = item.concept == .rules ? .afterClear : item.concept == .agents ? .newSession : .live
            return PlannedChange(
                itemId: item.id, enabled: nil, edits: [], moves: [item.location], effect: effect, warnings: [])
        }
    }

    private func removePlugin(_ item: Item, keepData: Bool, pending: inout [String: Data]) throws -> PlannedChange {
        let id = ChangeQueue.idOf(item)
        guard NameValidator.isValidPluginId(id) else { throw PlanError(reason: "Not a valid plugin id: \(id)") }
        if item.classification.ownership == .orphan {
            guard let file = item.enabledByFile else { throw PlanError(reason: "No settings file names \(id)") }
            let edit = try edit(file, reason: "Remove \(item.name)", pending: &pending) {
                try Self.removing(["enabledPlugins", .key(id)], from: $0, keeping: 0)
            }
            return PlannedChange(itemId: item.id, enabled: nil, edits: edit, effect: .reloadPlugins, warnings: [])
        }
        let inProject = item.scope == .project || item.scope == .local
        let scope = inProject ? item.scope.rawValue : "user"
        guard !inProject || item.projectPath != nil else { throw PlanError(reason: "No project for \(id)") }
        var settings = environment.userSettingsFile
        if let project = item.projectPath, inProject {
            settings =
                item.scope == .local ? environment.localSettingsFile(project) : environment.projectSettingsFile(project)
        }
        return PlannedChange(
            itemId: item.id, enabled: nil, edits: [],
            cli: [
                CliStep(
                    argv: ["plugin", "uninstall", id, "--scope", scope] + (keepData ? ["--keep-data"] : []),
                    workingDirectory: inProject ? item.projectPath : nil)
            ],
            cliTouches: [settings, environment.installedPluginsFile], effect: .reloadPlugins,
            warnings: keepData ? [] : ["Claude Code deletes this plugin's data folder when it leaves its last scope."],
            pluginCheck: PluginCheck(id: id, enabled: nil, scope: scope))
    }

    private func removeServer(_ item: Item, pending: inout [String: Data]) throws -> PlannedChange {
        let remote = item.description.hasPrefix("http") || item.description.hasPrefix("sse")
        let warnings = remote ? ["Removing a remote server also deletes its stored sign-in."] : []
        if item.scope == .project {
            let edit = try edit(item.location, reason: "Remove \(item.name)", pending: &pending) {
                try Self.removing(["mcpServers", .key(item.name)], from: $0, keeping: 1)
            }
            return PlannedChange(itemId: item.id, enabled: nil, edits: edit, effect: .newSession, warnings: warnings)
        }
        guard NameValidator.isValidName(item.name), !item.name.contains(".") else {
            throw PlanError(reason: "Not a valid server name: \(item.name)")
        }
        return PlannedChange(
            itemId: item.id, enabled: nil, edits: [],
            cli: [
                CliStep(
                    argv: ["mcp", "remove", item.name, "--scope", item.scope.rawValue],
                    workingDirectory: item.scope == .local ? item.projectPath : nil)
            ],
            cliTouches: [environment.claudeJsonFile], effect: .newSession, warnings: warnings)
    }

    private func removeHook(_ item: Item, pending: inout [String: Data]) throws -> PlannedChange {
        guard let position = Self.hookPosition(item) else { throw PlanError(reason: "Cannot locate \(item.name)") }
        let warnings =
            ["PreToolUse", "PermissionRequest"].contains(position.event)
            ? ["Guard hook: it can block or approve tool use, so removing it changes safety behaviour."] : []
        let edit = try edit(position.file, reason: "Remove \(item.name)", pending: &pending) { data in
            let settings = try JSONValue.parse(data)
            let records = HookReader.parse(settings["hooks"], file: position.file).0
            guard
                let record = records.first(where: {
                    $0.event == position.event && $0.groupIndex == position.group && $0.handlerIndex == position.handler
                }), item.name.hasSuffix(" · \(record.summary)")
            else { throw JSONEditError(reason: "this hook moved since the scan; scan again") }
            let group: [JSONPathComponent] = ["hooks", .key(position.event), .index(position.group)]
            let handlers = group + ["hooks"]
            let output = try JSONEdit.remove(data, path: handlers + [.index(position.handler)])
            guard try Self.value(at: handlers, in: output)?.arrayValue?.isEmpty == true else { return output }
            return try Self.removing(group, from: output, keeping: 0)
        }
        return PlannedChange(itemId: item.id, enabled: nil, edits: edit, effect: .live, warnings: warnings)
    }

    private func stashHook(_ item: Item, date: Date, pending: inout [String: Data]) throws -> PlannedChange {
        guard let position = Self.hookPosition(item) else { throw PlanError(reason: "Cannot locate \(item.name)") }
        guard let data = try pending[position.file] ?? read(position.file) else {
            throw PlanError(reason: "\(position.file) no longer exists")
        }
        var change = try removeHook(item, pending: &pending)
        let group: [JSONPathComponent] = ["hooks", .key(position.event), .index(position.group)]
        let path = group + ["hooks", .index(position.handler)]
        guard let handler = try Self.value(at: path, in: data), let raw = try JSONEdit.text(data, path: path),
            let groupValue = try Self.value(at: group, in: data)
        else { throw PlanError(reason: "Cannot locate \(item.name)") }
        let handlerText = String(decoding: raw, as: UTF8.self)
        let alone = groupValue["hooks"]?.arrayValue?.count == 1
        let digest = SHA256.hex(Data("\(position.file)|\(position.event)|\(position.order)|\(handlerText)".utf8))
        change.enabled = false
        change.stash = .put(
            HookStashEntry(
                id: "hook-\(position.event.lowercased())-\(digest.prefix(6))", sourceFile: position.file,
                event: position.event, matcher: groupValue["matcher"]?.stringValue, handler: handler,
                handlerText: handlerText,
                groupText: alone ? try JSONEdit.text(data, path: group).map { String(decoding: $0, as: UTF8.self) } : nil,
                position: .init(groupIndex: position.group, handlerIndex: position.handler),
                stashedAt: BackupStore.timestamp(date)))
        return change
    }

    private func edit(
        _ file: String, reason: String, pending: inout [String: Data], change: (Data) throws -> Data
    ) throws -> [FileEdit] {
        let base = try pending[file] ?? read(file)
        guard let base else { throw PlanError(reason: "\(file) no longer exists") }
        let after: Data
        do {
            after = try change(base)
        } catch let error as JSONEditError {
            throw PlanError(reason: "\(file): \(error.reason)")
        } catch {
            throw PlanError(reason: "\(file) is not valid JSON")
        }
        guard after != base else { return [] }
        pending[file] = after
        return [FileEdit(file: file, before: base, after: after, reason: reason)]
    }

    /// Reads `<file> › hooks.<event>[g].hooks[h]`, the location a hook item carries.
    private static func hookPosition(_ item: Item) -> (file: String, event: String, group: Int, handler: Int, order: [Int])? {
        guard item.concept == .hooks else { return nil }
        let parts = item.location.components(separatedBy: " › hooks.")
        guard parts.count == 2 else { return nil }
        let numbers = parts[1].split(whereSeparator: { "[]".contains($0) })
        guard numbers.count == 4, let group = Int(numbers[1]), let handler = Int(numbers[3]) else { return nil }
        return (parts[0], String(numbers[0]), group, handler, [group, handler])
    }

    private func plan(
        _ item: Item, enabled: Bool, writeScope: WriteScope?, activeProject: String?, date: Date,
        pending: inout [String: Data]
    ) throws -> PlannedChange {
        guard item.capabilities.toggle else {
            throw PlanError(reason: item.capabilities.reason ?? "\(item.name) cannot be turned on or off")
        }
        guard item.control.status != .unknown else {
            throw PlanError(reason: "The control for \(item.name) is not verified")
        }
        if item.control.mechanism == .hookStash {
            guard !enabled else { throw PlanError(reason: "A stashed hook comes back through restore") }
            return try stashHook(item, date: date, pending: &pending)
        }
        var step = try self.step(for: item, enabled: enabled, writeScope: writeScope, activeProject: activeProject)
        step.warnings += try overrides(
            of: item, enabled: enabled, writeScope: writeScope, project: activeProject ?? item.projectPath, pending: pending)
        let base = try pending[step.file] ?? read(step.file)
        let text = base ?? Data("{}\n".utf8)
        let after: Data
        do {
            after = try step.edit(text)
        } catch let error as JSONEditError {
            throw PlanError(reason: "\(step.file): \(error.reason)")
        }
        guard after != text else {
            return PlannedChange(itemId: item.id, enabled: enabled, edits: [], effect: step.effect, warnings: step.warnings)
        }
        pending[step.file] = after
        let reason = "\(enabled ? "Enable" : "Disable") \(item.name)"
        // With a warning, another scope decides, so the CLI is expected to disagree.
        let check =
            item.control.mechanism == .enabledPlugins && step.warnings.isEmpty
            ? PluginCheck(id: ChangeQueue.idOf(item), enabled: enabled, scope: nil) : nil
        return PlannedChange(
            itemId: item.id, enabled: enabled,
            edits: [FileEdit(file: step.file, before: base, after: after, reason: reason)], effect: step.effect,
            warnings: step.warnings, pluginCheck: check)
    }

    private struct Layer {
        let scope: SettingsScope
        let file: String
        let values: JSONValue

        /// Lowest to highest precedence [V S2, TECHNICAL-DESIGN section 6].
        var rank: Int { [.user, .project, .local, .managed].firstIndex(of: scope) ?? 0 }
    }

    /// Settings files in force, highest precedence first. One that cannot be read is skipped: the scan reported it.
    private func layers(project: String?, pending: [String: Data]) -> [Layer] {
        var files: [(SettingsScope, String)] = [(.managed, environment.managedSettingsFile)]
        if let project {
            files.append((.local, environment.localSettingsFile(project)))
            files.append((.project, environment.projectSettingsFile(project)))
        }
        files.append((.user, environment.userSettingsFile))
        return files.compactMap { scope, file in
            guard let data = pending[file] ?? (try? fileSystem.readFile(file)),
                let values = try? JSONValue.parse(data)
            else { return nil }
            return Layer(scope: scope, file: file, values: values)
        }
    }

    /// Whether another settings file defeats this change (`FR-F07-2`). Managed settings refuse it (`FR-F07-3`).
    private func overrides(
        of item: Item, enabled: Bool, writeScope: WriteScope?, project: String?, pending: [String: Data]
    ) throws -> [String] {
        guard let writeScope else { return [] }
        let all = layers(project: project, pending: pending)
        let written = Layer(scope: writeScope.scope, file: writeScope.file, values: .null)

        /// A key per scope: the highest scope that sets it decides.
        func highest(_ value: (Layer) -> Bool?) throws -> [String] {
            let above = all.filter { $0.rank > written.rank }
            guard let layer = above.first(where: { value($0) != nil }), value(layer) != enabled else { return [] }
            return try defeated(by: layer)
        }
        /// A list adds up across files: one entry anywhere keeps the item off.
        func listed(_ path: [String], _ entry: String) throws -> [String] {
            guard enabled else { return [] }
            let others = all.filter { $0.file != writeScope.file }
            let holder = others.first { layer in
                let list = path.reduce(layer.values as JSONValue?) { $0?[$1] }
                return list?.arrayValue?.contains(.string(entry)) == true
            }
            return try holder.map(defeated) ?? []
        }
        func defeated(by layer: Layer) throws -> [String] {
            guard layer.scope != .managed else {
                throw PlanError(reason: "Your organisation's managed settings decide \(item.name)")
            }
            let scope = writeScope.scope.rawValue
            return [
                enabled
                    ? "Enabled in \(scope) settings but stays off: \(layer.scope.rawValue) settings disable it"
                    : "Disabled in \(scope) settings but still loads: \(layer.scope.rawValue) settings enable it"
            ]
        }

        switch item.control.mechanism {
        case .enabledPlugins:
            let id = ChangeQueue.idOf(item)
            return try highest { $0.values["enabledPlugins"]?[id]?.boolValue }
        case .skillOverrides:
            let name = ChangeQueue.idOf(item)
            return try highest { layer in layer.values["skillOverrides"]?[name]?.stringValue.map { $0 != "off" } }
        case .permissionsDeny: return try listed(["permissions", "deny"], "Agent(\(item.name))")
        case .claudeMdExcludes: return try listed(["claudeMdExcludes"], item.location)
        case .disabledMcpjsonServers: return try listed(["disabledMcpjsonServers"], item.name)
        default: return []
        }
    }

    private struct Layer {
        let scope: SettingsScope
        let file: String
        let values: JSONValue

        /// Lowest to highest precedence [V S2, TECHNICAL-DESIGN section 6].
        var rank: Int { [.user, .project, .local, .managed].firstIndex(of: scope) ?? 0 }
    }

    /// Settings files in force, highest precedence first. One that cannot be read is skipped: the scan reported it.
    private func layers(project: String?, pending: [String: Data]) -> [Layer] {
        var files: [(SettingsScope, String)] = [(.managed, environment.managedSettingsFile)]
        if let project {
            files.append((.local, environment.localSettingsFile(project)))
            files.append((.project, environment.projectSettingsFile(project)))
        }
        files.append((.user, environment.userSettingsFile))
        return files.compactMap { scope, file in
            guard let data = pending[file] ?? (try? fileSystem.readFile(file)),
                let values = try? JSONValue.parse(data)
            else { return nil }
            return Layer(scope: scope, file: file, values: values)
        }
    }

    /// Whether another settings file defeats this change (`FR-F07-2`). Managed settings refuse it (`FR-F07-3`).
    private func overrides(
        of item: Item, enabled: Bool, writeScope: WriteScope?, project: String?, pending: [String: Data]
    ) throws -> [String] {
        guard let writeScope else { return [] }
        let all = layers(project: project, pending: pending)
        let written = Layer(scope: writeScope.scope, file: writeScope.file, values: .null)

        /// A key per scope: the highest scope that sets it decides.
        func highest(_ value: (Layer) -> Bool?) throws -> [String] {
            let above = all.filter { $0.rank > written.rank }
            guard let layer = above.first(where: { value($0) != nil }), value(layer) != enabled else { return [] }
            return try defeated(by: layer)
        }
        /// A list adds up across files: one entry anywhere keeps the item off.
        func listed(_ path: [String], _ entry: String) throws -> [String] {
            guard enabled else { return [] }
            let others = all.filter { $0.file != writeScope.file }
            let holder = others.first { layer in
                let list = path.reduce(layer.values as JSONValue?) { $0?[$1] }
                return list?.arrayValue?.contains(.string(entry)) == true
            }
            return try holder.map(defeated) ?? []
        }
        func defeated(by layer: Layer) throws -> [String] {
            guard layer.scope != .managed else {
                throw PlanError(reason: "Your organisation's managed settings decide \(item.name)")
            }
            let scope = writeScope.scope.rawValue
            return [
                enabled
                    ? "Enabled in \(scope) settings but stays off: \(layer.scope.rawValue) settings disable it"
                    : "Disabled in \(scope) settings but still loads: \(layer.scope.rawValue) settings enable it"
            ]
        }

        switch item.control.mechanism {
        case .enabledPlugins:
            let id = ChangeQueue.idOf(item)
            return try highest { $0.values["enabledPlugins"]?[id]?.boolValue }
        case .skillOverrides:
            let name = ChangeQueue.idOf(item)
            return try highest { layer in layer.values["skillOverrides"]?[name]?.stringValue.map { $0 != "off" } }
        case .permissionsDeny: return try listed(["permissions", "deny"], "Agent(\(item.name))")
        case .claudeMdExcludes: return try listed(["claudeMdExcludes"], item.location)
        case .disabledMcpjsonServers: return try listed(["disabledMcpjsonServers"], item.name)
        default: return []
        }
    }

    private struct Step {
        let file: String
        let effect: PlanEffect
        var warnings: [String] = []
        let edit: (Data) throws -> Data
    }

    private func step(
        for item: Item, enabled: Bool, writeScope: WriteScope?, activeProject: String?
    ) throws -> Step {
        func settingsFile() throws -> String {
            guard let writeScope else { throw PlanError(reason: "Choose a project to write this change to") }
            return writeScope.file
        }
        switch item.control.mechanism {
        case .enabledPlugins:
            let id = ChangeQueue.idOf(item)
            return Step(file: try settingsFile(), effect: .reloadPlugins) {
                try JSONEdit.set($0, path: ["enabledPlugins", .key(id)], value: .bool(enabled))
            }
        case .skillOverrides:
            let name = ChangeQueue.idOf(item)
            return Step(file: try settingsFile(), effect: .live) {
                try Self.override(name, enabled: enabled, wasEnabled: item.enabled, in: $0)
            }
        case .claudeMdExcludes:
            let glob = "*?[]{}".contains { item.location.contains($0) }
            let warnings = glob ? ["This path holds glob characters, so the entry may match other files."] : []
            return Step(file: try settingsFile(), effect: .afterClear, warnings: warnings) {
                try Self.list(["claudeMdExcludes"], item.location, present: !enabled, in: $0)
            }
        case .permissionsDeny:
            return Step(file: try settingsFile(), effect: .live) {
                try Self.list(["permissions", "deny"], "Agent(\(item.name))", present: !enabled, in: $0)
            }
        case .disabledMcpjsonServers:
            if enabled, item.enabledBy == "disabledMcpServers" {
                return try projectEntry(item, enabled: enabled, activeProject: activeProject)
            }
            return Step(file: try settingsFile(), effect: .newSession) {
                try Self.list(["disabledMcpjsonServers"], item.name, present: !enabled, in: $0)
            }
        case .disabledMcpServers:
            return try projectEntry(item, enabled: enabled, activeProject: activeProject)
        case .hookStash, .syncSetting, .parentPlugin, .none:
            throw PlanError(reason: "\(item.name) has no switch of its own")
        }
    }

    /// `disabledMcpServers` lives in the project's entry of `.claude.json`, keyed by the real path [V S1]. The
    /// entry stays when the list empties: Claude Code owns it.
    private func projectEntry(_ item: Item, enabled: Bool, activeProject: String?) throws -> Step {
        guard let project = item.projectPath ?? activeProject else {
            throw PlanError(reason: "Choose the project to change \(item.name) in")
        }
        let key = fileSystem.resolvingSymlinks(project)
        return Step(
            file: environment.claudeJsonFile, effect: .newSession,
            warnings: ["This applies to \(project) only. Other projects keep their own setting."]
        ) {
            try Self.list(["projects", .key(key), "disabledMcpServers"], item.name, present: !enabled, in: $0, keeping: 2)
        }
    }

    private func read(_ file: String) throws -> Data? {
        do {
            return try fileSystem.readFile(file)
        } catch {
            throw PlanError(reason: "Cannot read \(file)")
        }
    }

    /// Off is written as `"off"`. On removes the entry, or says `"on"` to beat a lower scope [V S2].
    private static func override(_ name: String, enabled: Bool, wasEnabled: Bool, in data: Data) throws -> Data {
        let path: [JSONPathComponent] = ["skillOverrides", .key(name)]
        guard enabled else { return try JSONEdit.set(data, path: path, value: .string("off")) }
        if try value(at: path, in: data) != nil { return try removing(path, from: data, keeping: 0) }
        return wasEnabled ? data : try JSONEdit.set(data, path: path, value: .string("on"))
    }

    /// Puts a string in the array at `path`, or takes it out. An array or object this empties goes too, down to
    /// `keeping` path steps, so a change undone leaves the file as it was.
    private static func list(
        _ path: [JSONPathComponent], _ entry: String, present: Bool, in data: Data, keeping: Int = 0
    ) throws -> Data {
        let wanted = JSONValue.string(entry)
        let elements = try value(at: path, in: data)?.arrayValue ?? []
        if present {
            return elements.contains(wanted) ? data : try JSONEdit.insert(data, arrayAt: path, value: wanted)
        }
        var output = data
        for index in elements.indices.reversed() where elements[index] == wanted {
            output = try JSONEdit.remove(output, path: path + [.index(index)])
        }
        guard elements.contains(wanted) else { return data }
        return try pruned(path, in: output, keeping: keeping)
    }

    private static func removing(_ path: [JSONPathComponent], from data: Data, keeping: Int) throws -> Data {
        try pruned(Array(path.dropLast()), in: try JSONEdit.remove(data, path: path), keeping: keeping)
    }

    private static func pruned(_ path: [JSONPathComponent], in data: Data, keeping: Int) throws -> Data {
        var output = data
        var current = path
        while current.count > keeping, let value = try value(at: current, in: output), isEmpty(value) {
            output = try JSONEdit.remove(output, path: current)
            current.removeLast()
        }
        return output
    }

    private static func isEmpty(_ value: JSONValue) -> Bool {
        value.arrayValue?.isEmpty == true || value.objectValue?.isEmpty == true
    }

    private static func value(at path: [JSONPathComponent], in data: Data) throws -> JSONValue? {
        var current: JSONValue?
        do {
            current = try JSONValue.parse(data)
        } catch {
            throw JSONEditError(reason: "invalid JSON: \(error)")
        }
        for component in path {
            switch component {
            case .key(let key): current = current?[key]
            case .index(let index):
                guard let array = current?.arrayValue, array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }
}
