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

public struct PlannedChange: Sendable, Equatable {
    public let itemId: String
    public let enabled: Bool
    /// Empty when the file already says what was asked.
    public let edits: [FileEdit]
    public let effect: PlanEffect
    public let warnings: [String]
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
        _ item: Item, enabled: Bool, writeScope: WriteScope?, activeProject: String?
    ) throws -> PlannedChange {
        var pending: [String: Data] = [:]
        return try plan(item, enabled: enabled, writeScope: writeScope, activeProject: activeProject, pending: &pending)
    }

    /// Plans in order; a later change to a file builds on the earlier one.
    public func setEnabled(
        _ changes: [(item: Item, enabled: Bool)], writeScope: WriteScope?, activeProject: String?
    ) throws -> [PlannedChange] {
        var pending: [String: Data] = [:]
        return try changes.map {
            try plan($0.item, enabled: $0.enabled, writeScope: writeScope, activeProject: activeProject, pending: &pending)
        }
    }

    private func plan(
        _ item: Item, enabled: Bool, writeScope: WriteScope?, activeProject: String?, pending: inout [String: Data]
    ) throws -> PlannedChange {
        guard item.capabilities.toggle else {
            throw PlanError(reason: item.capabilities.reason ?? "\(item.name) cannot be turned on or off")
        }
        guard item.control.status != .unknown else {
            throw PlanError(reason: "The control for \(item.name) is not verified")
        }
        let step = try self.step(for: item, enabled: enabled, writeScope: writeScope, activeProject: activeProject)
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
        return PlannedChange(
            itemId: item.id, enabled: enabled,
            edits: [FileEdit(file: step.file, before: base, after: after, reason: reason)], effect: step.effect,
            warnings: step.warnings)
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
        case .hookStash:
            throw PlanError(reason: "Hooks are planned with the stash, which is not built yet")
        case .syncSetting, .parentPlugin, .none:
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
