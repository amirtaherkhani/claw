import Foundation

/// What a change does to an item.
public enum ControlOperation: String, Sendable, CaseIterable, Codable {
    case enable, disable, remove
}

/// One kind of change: an operation on one concept.
public struct ControlAction: Hashable, Sendable, Codable {
    public let concept: Concept
    public let operation: ControlOperation

    public init(_ concept: Concept, _ operation: ControlOperation) {
        self.concept = concept
        self.operation = operation
    }
}

/// A `claude` command for one action, as an argument template. No shell ever sees it (`NFR-SEC-2`).
///
/// Placeholders: `{id}` is the item's id (`name@marketplace` for a plugin), `{name}` its name, `{scope}` the settings
/// scope written (`user`, `project`, `local`). `{keep-data}` becomes `--keep-data` when the data is kept, or nothing.
public struct ClaudeCommand: Sendable, Equatable {
    public let template: [String]
    /// Scopes the command accepts in `--scope`.
    public let scopes: Set<SettingsScope>

    public init(_ template: [String], scopes: Set<SettingsScope>) {
        self.template = template
        self.scopes = scopes
    }

    public func argv(id: String, name: String, scope: SettingsScope, keepData: Bool = true) -> [String] {
        template.compactMap { word in
            switch word {
            case "{keep-data}": keepData ? "--keep-data" : nil
            default:
                word.replacingOccurrences(of: "{id}", with: id).replacingOccurrences(of: "{name}", with: name)
                    .replacingOccurrences(of: "{scope}", with: scope.rawValue)
            }
        }
    }
}

/// Which changes go through Claude Code's own `claude` command, in one table (ADR-0004). Everything not listed here
/// is done by Claw itself, with the file edits the planner makes. When Claude Code gains a command, adding its row
/// here moves that action to the CLI; the planner still works out what the command should write, shows it in the
/// review and checks it after the run.
public struct CommandCatalog: Sendable, Equatable {
    public var commands: [ControlAction: ClaudeCommand]

    public init(commands: [ControlAction: ClaudeCommand]) {
        self.commands = commands
    }

    /// Claude Code 2.1.319: `claude plugin` and `claude mcp` are the only command-line controls. MCP on and off,
    /// skills, commands, subagents, rules and hooks have none (`/mcp enable` works only inside a session).
    public static let standard = CommandCatalog(commands: [
        ControlAction(.plugins, .enable): ClaudeCommand(
            ["plugin", "enable", "{id}", "--scope", "{scope}"], scopes: [.user, .project, .local]),
        ControlAction(.plugins, .disable): ClaudeCommand(
            ["plugin", "disable", "{id}", "--scope", "{scope}"], scopes: [.user, .project, .local]),
        ControlAction(.plugins, .remove): ClaudeCommand(
            ["plugin", "uninstall", "{id}", "--scope", "{scope}", "{keep-data}"], scopes: [.user, .project, .local]),
        ControlAction(.mcp, .remove): ClaudeCommand(
            ["mcp", "remove", "{name}", "--scope", "{scope}"], scopes: [.user, .project, .local]),
    ])

    /// No command at all: Claw does every change itself.
    public static let none = CommandCatalog(commands: [:])

    public func command(_ action: ControlAction, scope: SettingsScope) -> ClaudeCommand? {
        guard let command = commands[action], command.scopes.contains(scope) else { return nil }
        return command
    }
}

/// How one change to an item is made, for the item's detail and the docs.
public enum ControlRoute: Sendable, Equatable {
    /// Claude Code's command, as shown text (`claude plugin disable kit@m --scope user`).
    case claude(String)
    /// Claw edits or moves files itself, and why Claude Code's command does not do it.
    case claw(String, reason: String)
}

extension CommandCatalog {
    /// The route of each operation the item allows: enable or disable (whichever applies), then remove.
    public func routes(for item: Item, scope: SettingsScope?, claudeAvailable: Bool) -> [(ControlOperation, ControlRoute)] {
        var operations: [ControlOperation] = []
        if item.capabilities.toggle { operations.append(item.enabled ? .disable : .enable) }
        if item.capabilities.remove { operations.append(.remove) }
        return operations.map { operation in
            let written = operation == .remove ? SettingsScope(rawValue: item.scope.rawValue) : scope
            let how = Self.clawRoute(item, operation)
            guard let written, let command = command(ControlAction(item.concept, operation), scope: written) else {
                let reason =
                    item.concept == .hooks
                    ? "Claude Code has no switch for one hook." : "Claude Code has no command for this yet."
                return (operation, .claw(how, reason: reason))
            }
            if item.classification.ownership == .orphan {
                return (operation, .claw(how, reason: "It is not installed, so Claude Code's command cannot act on it."))
            }
            guard claudeAvailable else {
                return (operation, .claw(how, reason: "The claude command was not found, so Claw does it itself."))
            }
            let argv = command.argv(id: ChangeQueue.idOf(item), name: item.name, scope: written)
            return (operation, .claude("claude " + argv.joined(separator: " ")))
        }
    }

    static func clawRoute(_ item: Item, _ operation: ControlOperation) -> String {
        if operation == .remove {
            switch item.concept {
            case .hooks: return "Claw takes the entry out of hooks"
            case .mcp: return "Claw takes the server out of .mcp.json"
            case .plugins: return "Claw takes the plugin out of enabledPlugins"
            default: return "Claw moves it to the backup folder"
            }
        }
        switch item.control.mechanism {
        case .enabledPlugins: return "Claw sets enabledPlugins in settings"
        case .skillOverrides: return "Claw sets skillOverrides in settings"
        case .claudeMdExcludes: return "Claw edits claudeMdExcludes in settings"
        case .permissionsDeny: return "Claw edits permissions.deny in settings"
        case .disabledMcpjsonServers: return "Claw edits disabledMcpjsonServers in settings"
        case .disabledMcpServers: return "Claw edits the project's disabledMcpServers in ~/.claude.json"
        case .hookStash: return "Claw moves the entry to its hook stash and back"
        case .syncSetting, .parentPlugin, .none: return "No switch of its own"
        }
    }
}

extension JSONValue {
    /// This value with the key at `path` set, or removed when `value` is `nil`. Missing objects on the way are
    /// created; a value that is not an object on the way is replaced by one.
    func setting(_ path: [String], to value: JSONValue?) -> JSONValue {
        guard let first = path.first else { return value ?? .null }
        var object = objectValue ?? [:]
        if path.count == 1 {
            object[first] = value
        } else {
            object[first] = (object[first] ?? .object([:])).setting(Array(path.dropFirst()), to: value)
        }
        return .object(object)
    }
}
