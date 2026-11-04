import Foundation

public enum VerificationStatus: String, Codable, Sendable {
    case verified, assumed, unknown
}

/// The native switch that turns an item on or off (TECHNICAL-DESIGN section 3.3).
public enum ControlMechanism: String, Codable, Sendable {
    case enabledPlugins, skillOverrides, claudeMdExcludes, permissionsDeny
    case disabledMcpjsonServers, disabledMcpServers, hookStash, syncSetting
    /// Controlled only through the plugin that provides it.
    case parentPlugin
    case none
}

public struct ControlRef: Codable, Sendable, Equatable {
    public let mechanism: ControlMechanism
    /// Display string, for example `enabledPlugins["ecc@ecc"]`.
    public let key: String
    public let status: VerificationStatus

    public init(mechanism: ControlMechanism, key: String, status: VerificationStatus) {
        self.mechanism = mechanism
        self.key = key
        self.status = status
    }
}

public struct Capabilities: Codable, Sendable, Equatable {
    public let edit: Bool
    public let toggle: Bool
    public let remove: Bool
    public let removeLabel: String?
    /// Shown as a tooltip when an action is unavailable.
    public let reason: String?

    public init(edit: Bool, toggle: Bool, remove: Bool, removeLabel: String?, reason: String?) {
        self.edit = edit
        self.toggle = toggle
        self.remove = remove
        self.removeLabel = removeLabel
        self.reason = reason
    }

    /// Capability matrix, PRD section 4.4. `isPlugin` selects plugin-specific labels.
    public static func forOwnership(_ ownership: Ownership, isPlugin: Bool) -> Capabilities {
        switch ownership {
        case .personal:
            Capabilities(
                edit: true, toggle: true, remove: true,
                removeLabel: isPlugin ? "Uninstall" : "Move to backup", reason: nil)
        case .market:
            Capabilities(
                edit: false, toggle: true, remove: true, removeLabel: "Uninstall",
                reason: "Installed from a marketplace: edit the source upstream")
        case .synced:
            Capabilities(
                edit: false, toggle: isPlugin, remove: false, removeLabel: nil,
                reason: "Synced from your claude.ai account: manage it on claude.ai")
        case .plugin:
            Capabilities(
                edit: false, toggle: false, remove: false, removeLabel: nil,
                reason: "Provided by a plugin: enable, disable or remove the plugin")
        case .managed:
            Capabilities(
                edit: false, toggle: false, remove: false, removeLabel: nil,
                reason: "Set by your organization's managed policy")
        case .orphan:
            Capabilities(
                edit: false, toggle: false, remove: true, removeLabel: "Remove entry",
                reason: "Its marketplace or source is missing")
        }
    }
}

public struct Problem: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable {
        case error, warning, note
    }

    public let severity: Severity
    public let message: String
    public let file: String?

    public init(_ severity: Severity, _ message: String, file: String? = nil) {
        self.severity = severity
        self.message = message
        self.file = file
    }
}

public enum ItemScope: String, Codable, Sendable {
    case managed, user, project, local, plugin, synced
}

public struct Item: Codable, Sendable, Identifiable, Equatable {
    /// Stable: `<concept>:<scope>:<key>`.
    public let id: String
    public let concept: Concept
    public let name: String
    public let description: String
    public let scope: ItemScope
    public let projectPath: String?
    public let classification: Classification
    public let bucket: Bucket
    /// File or folder that defines the item.
    public let location: String
    public let enabled: Bool
    /// Settings source that decided `enabled`, for example `project`.
    public let enabledBy: String?
    public let enabledByFile: String?
    public let control: ControlRef
    public let capabilities: Capabilities
    /// Plugin id when the item comes from a plugin.
    public let providedBy: String?
    public let problems: [Problem]

    public init(
        concept: Concept,
        key: String,
        name: String,
        description: String,
        scope: ItemScope,
        projectPath: String? = nil,
        classification: Classification,
        location: String,
        enabled: Bool,
        enabledBy: String? = nil,
        enabledByFile: String? = nil,
        control: ControlRef,
        capabilities: Capabilities,
        providedBy: String? = nil,
        problems: [Problem] = []
    ) {
        self.id = "\(concept.rawValue):\(scope.rawValue):\(key)"
        self.concept = concept
        self.name = name
        self.description = description
        self.scope = scope
        self.projectPath = projectPath
        self.classification = classification
        self.bucket = classification.ownership.bucket
        self.location = location
        self.enabled = enabled
        self.enabledBy = enabledBy
        self.enabledByFile = enabledByFile
        self.control = control
        self.capabilities = capabilities
        self.providedBy = providedBy
        self.problems = problems
    }
}

public struct ScanTarget: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case mac, folder
    }

    public let kind: Kind
    public let path: String?

    public static let mac = ScanTarget(kind: .mac, path: nil)
    public static func folder(_ path: String) -> ScanTarget { ScanTarget(kind: .folder, path: path) }
}

public struct ScanResult: Codable, Sendable {
    public let target: ScanTarget
    public let startedAt: Date
    public let finishedAt: Date
    public let partial: Bool
    public let claudeCodeVersion: String?
    public let items: [Item]
    public let problems: [Problem]

    public init(
        target: ScanTarget,
        startedAt: Date,
        finishedAt: Date,
        partial: Bool,
        claudeCodeVersion: String?,
        items: [Item],
        problems: [Problem]
    ) {
        self.target = target
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.partial = partial
        self.claudeCodeVersion = claudeCodeVersion
        self.items = items
        self.problems = problems
    }
}
