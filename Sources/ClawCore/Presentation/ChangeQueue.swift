import Foundation

/// One line of a change preview.
public struct DiffLine: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case context, removed, added, note }
    public let kind: Kind
    public let text: String
    public let id: Int

    public init(_ kind: Kind, _ text: String, id: Int) {
        self.kind = kind
        self.text = text
        self.id = id
    }
}

/// A change the user queued for review. Nothing is written until Apply (milestone M2).
public struct PendingChange: Sendable, Equatable, Identifiable {
    public enum Action: String, Sendable { case enable, disable, remove }

    public let itemId: String
    public let action: Action
    public let concept: Concept
    public let title: String
    /// File that will change, or the CLI command for steps that run `claude`.
    public let target: String
    public let preview: [DiffLine]
    public let notes: [String]

    public var id: String { "\(itemId)#\(action.rawValue)" }
}

/// Where a toggle writes, by scope (FR-F13). `nil` when the scope needs an active project.
public struct WriteScope: Sendable, Equatable {
    public let scope: SettingsScope
    public let file: String

    public static func resolve(_ scope: SettingsScope, environment: ClaudeEnvironment, activeProject: String?)
        -> WriteScope?
    {
        switch scope {
        case .user: return WriteScope(scope: .user, file: environment.userSettingsFile)
        case .project:
            return activeProject.map { WriteScope(scope: .project, file: environment.projectSettingsFile($0)) }
        case .local:
            return activeProject.map { WriteScope(scope: .local, file: environment.localSettingsFile($0)) }
        case .managed: return nil
        }
    }
}

/// Queued changes, in order. Toggling an item back removes its pending change.
public struct ChangeQueue: Sendable, Equatable {
    public private(set) var changes: [PendingChange] = []

    public init() {}

    public var isEmpty: Bool { changes.isEmpty }
    public var count: Int { changes.count }

    public func pending(for itemId: String) -> PendingChange? { changes.first { $0.itemId == itemId } }

    /// The state the UI should show for an item, counting queued changes.
    public func effectiveEnabled(_ item: Item) -> Bool {
        switch pending(for: item.id)?.action {
        case .enable: true
        case .disable: false
        case .remove, nil: item.enabled
        }
    }

    public func isQueuedForRemoval(_ item: Item) -> Bool { pending(for: item.id)?.action == .remove }

    /// Flips an item's queued state. Returns a message when the item cannot be toggled.
    @discardableResult
    public mutating func toggle(_ item: Item, writeScope: WriteScope?, home: String) -> String? {
        guard item.capabilities.toggle else { return item.capabilities.reason ?? "This item has no switch." }
        if let existing = pending(for: item.id), existing.action != .remove {
            changes.removeAll { $0.itemId == item.id }
            return nil
        }
        changes.removeAll { $0.itemId == item.id }
        let action: PendingChange.Action = item.enabled ? .disable : .enable
        changes.append(Self.make(item, action: action, writeScope: writeScope, home: home))
        return nil
    }

    /// Queues or unqueues removal.
    @discardableResult
    public mutating func toggleRemoval(_ item: Item, home: String) -> String? {
        guard item.capabilities.remove else { return item.capabilities.reason ?? "This item cannot be removed here." }
        if isQueuedForRemoval(item) {
            changes.removeAll { $0.itemId == item.id }
            return nil
        }
        changes.removeAll { $0.itemId == item.id }
        changes.append(Self.make(item, action: .remove, writeScope: nil, home: home))
        return nil
    }

    public mutating func discard(_ change: PendingChange) { changes.removeAll { $0.id == change.id } }
    public mutating func clear() { changes.removeAll() }

    // MARK: Previews

    /// Preview of what a change would do, without queuing it (detail view "On apply").
    public static func preview(_ item: Item, action: PendingChange.Action, writeScope: WriteScope?, home: String)
        -> PendingChange
    {
        make(item, action: action, writeScope: writeScope, home: home)
    }

    static func make(_ item: Item, action: PendingChange.Action, writeScope: WriteScope?, home: String) -> PendingChange {
        let verb = action == .enable ? "Enable" : action == .disable ? "Disable" : (item.capabilities.removeLabel ?? "Remove")
        var lines: [(DiffLine.Kind, String)] = []
        var notes: [String] = []
        var target = ItemPresentation.abbreviate(writeScope?.file ?? ItemPresentation.file(item), home: home)
        let on = action == .enable

        if action == .remove {
            if item.concept == .plugins {
                let scope = item.scope == .project || item.scope == .local ? item.scope.rawValue : "user"
                target = "claude plugin uninstall \(idOf(item)) --scope \(scope)"
                lines = [(.note, "Runs the claude CLI; the plugin's cache folder is removed by Claude Code")]
                notes.append("Plugin data is kept unless you choose otherwise when applying.")
            } else if item.concept == .hooks {
                lines = [(.removed, item.name), (.note, "A copy is kept in the backup")]
            } else if item.concept == .mcp {
                lines = [(.removed, "\"\(item.name)\": { … }"), (.note, "A copy is kept in the backup")]
            } else {
                target = ItemPresentation.abbreviate(ItemPresentation.file(item), home: home)
                lines = [(.removed, target), (.note, "Moved to the backup folder, never hard-deleted")]
            }
        } else {
            switch item.control.mechanism {
            case .enabledPlugins:
                lines = [
                    (.context, "\"enabledPlugins\": {"), (.removed, "  \"\(idOf(item))\": \(!on),"),
                    (.added, "  \"\(idOf(item))\": \(on),"),
                ]
                notes.append("Open sessions need /reload-plugins or a restart to pick up the change.")
            case .skillOverrides:
                lines = [(.context, "\"skillOverrides\": {"), (on ? .removed : .added, "  \"\(plainName(item))\": \"off\",")]
            case .claudeMdExcludes:
                lines = [(.context, "\"claudeMdExcludes\": ["), (on ? .removed : .added, "  \"\(item.location)\",")]
            case .permissionsDeny:
                lines = [
                    (.context, "\"permissions\": { \"deny\": ["), (on ? .removed : .added, "  \"Agent(\(item.name))\","),
                ]
            case .disabledMcpjsonServers:
                lines = [(.context, "\"disabledMcpjsonServers\": ["), (on ? .removed : .added, "  \"\(item.name)\",")]
            case .disabledMcpServers:
                target = "~/.claude.json"
                lines = [
                    (.context, "\"projects\": { … \"disabledMcpServers\": ["), (on ? .removed : .added, "  \"\(item.name)\","),
                ]
            case .hookStash:
                target = ItemPresentation.abbreviate(ItemPresentation.file(item), home: home)
                lines =
                    on
                    ? [(.note, "Restored from Claw's stash"), (.added, item.name)]
                    : [(.removed, item.name), (.note, "Copy kept in Claw's stash, restorable")]
                notes.append("Claude Code has no per-hook disable, so Claw removes the entry and restores it later.")
            case .syncSetting, .parentPlugin, .none:
                lines = [(.note, ItemPresentation.how(item))]
            }
        }
        if item.control.status == .unknown {
            notes.append("The key this change uses is not verified yet; it is checked in a spike before Apply is enabled.")
        }
        return PendingChange(
            itemId: item.id, action: action, concept: item.concept, title: "\(verb) \(item.name)", target: target,
            preview: lines.enumerated().map { DiffLine($0.element.0, $0.element.1, id: $0.offset) }, notes: notes)
    }

    /// Plugin id from the control key `enabledPlugins["id"]`, or the item name.
    private static func idOf(_ item: Item) -> String {
        let key = item.control.key
        guard let open = key.range(of: "[\""), let close = key.range(of: "\"]", options: .backwards),
            open.upperBound <= close.lowerBound
        else { return item.name }
        return String(key[open.upperBound..<close.lowerBound])
    }

    private static func plainName(_ item: Item) -> String {
        item.name.hasPrefix("/") ? String(item.name.dropFirst()) : item.name
    }
}
