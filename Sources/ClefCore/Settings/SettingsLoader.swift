import Foundation

/// One parsed settings file.
public struct SettingsLayer: Sendable, Equatable {
    public let scope: SettingsScope
    public let file: String
    public let projectPath: String?
    public let values: [String: JSONValue]

    public init(scope: SettingsScope, file: String, projectPath: String?, values: [String: JSONValue]) {
        self.scope = scope
        self.file = file
        self.projectPath = projectPath
        self.values = values
    }

    /// `enabledPlugins` entries with a boolean value; other entries are reported by the loader.
    public var enabledPlugins: [String: Bool] {
        values["enabledPlugins"]?.objectValue?.compactMapValues(\.boolValue) ?? [:]
    }

    /// `skillOverrides` entries: `on`, `name-only`, `user-invocable-only` or `off` [V `skills`].
    public var skillOverrides: [String: String] {
        values["skillOverrides"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
    }
}

public struct SettingsLoadResult: Sendable {
    public let layers: [SettingsLayer]
    public let problems: [Problem]
}

/// Reads settings files. Never throws for bad content: a malformed file becomes a `Problem`.
public struct SettingsLoader: Sendable {
    private let fs: any ReadonlyFileSystem

    public init(fileSystem: any ReadonlyFileSystem) {
        self.fs = fileSystem
    }

    /// Loads one file. Returns no layer when the file is missing or unusable.
    public func load(scope: SettingsScope, file: String, projectPath: String? = nil) -> (SettingsLayer?, [Problem]) {
        let data: Data
        do {
            guard let read = try fs.readFile(file) else { return (nil, []) }
            data = read
        } catch {
            return (nil, [Problem(.error, "Cannot read settings file: \(error.localizedDescription)", file: file)])
        }
        if data.isEmpty { return (nil, [Problem(.warning, "Settings file is empty", file: file)]) }

        let value: JSONValue
        do {
            value = try JSONValue.parse(data)
        } catch {
            return (nil, [Problem(.error, "Settings file is not valid JSON; it was skipped", file: file)])
        }
        guard let object = value.objectValue else {
            return (nil, [Problem(.error, "Settings file must contain a JSON object; it was skipped", file: file)])
        }

        var problems: [Problem] = []
        for key in ["enabledPlugins", "skillOverrides"] {
            guard let entry = object[key] else { continue }
            guard let map = entry.objectValue else {
                problems.append(Problem(.warning, "`\(key)` is not an object; it was ignored", file: file))
                continue
            }
            let bad = map.filter { key == "enabledPlugins" ? $0.value.boolValue == nil : $0.value.stringValue == nil }
            for name in bad.keys.sorted() {
                problems.append(Problem(.warning, "`\(key)[\"\(name)\"]` has an unexpected type; it was ignored", file: file))
            }
        }
        return (SettingsLayer(scope: scope, file: file, projectPath: projectPath, values: object), problems)
    }

    /// Managed, User, and Project + Local for each project.
    /// Not read yet: `managed-settings.d/` drop-ins and MDM profiles (spike S10), `--settings` files.
    public func loadAll(environment env: ClaudeEnvironment) -> SettingsLoadResult {
        var layers: [SettingsLayer] = []
        var problems: [Problem] = []

        func add(_ scope: SettingsScope, _ file: String, _ project: String?) {
            let (layer, found) = load(scope: scope, file: file, projectPath: project)
            if let layer { layers.append(layer) }
            problems.append(contentsOf: found)
        }

        add(.managed, env.managedSettingsFile, nil)
        add(.user, env.userSettingsFile, nil)
        for project in env.projects {
            add(.project, env.projectSettingsFile(project), project)
            add(.local, env.localSettingsFile(project), project)
        }
        return SettingsLoadResult(layers: layers, problems: problems)
    }
}
