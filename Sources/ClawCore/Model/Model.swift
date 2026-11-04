import Foundation

/// The seven configuration concepts the app manages (PRD section 4.1).
public enum Concept: String, Codable, Sendable, CaseIterable {
    case plugins, skills, commands, rules, agents, mcp, hooks
}

/// Settings scopes, highest precedence first: Managed > (--settings) > Local > Project > User [V `settings`].
public enum SettingsScope: String, Codable, Sendable, CaseIterable {
    case managed, local, project, user
}

/// Who controls an item (PRD section 4.3).
public enum Ownership: String, Codable, Sendable, CaseIterable {
    case personal, market, synced, plugin, managed, orphan

    /// Only Personal items are "Yours"; Orphaned items need attention; everything else is read-only.
    public var bucket: Bucket {
        switch self {
        case .personal: .yours
        case .orphan: .attention
        case .market, .synced, .plugin, .managed: .readonly
        }
    }
}

public enum Bucket: String, Codable, Sendable, CaseIterable {
    case yours, readonly, attention
}

public struct Classification: Codable, Sendable, Equatable {
    public let ownership: Ownership
    /// Rule id from TECHNICAL-DESIGN section 5 (P1 to P8 for plugins, L* for location rules).
    public let rule: String
    public let evidence: [String]

    public init(ownership: Ownership, rule: String, evidence: [String]) {
        self.ownership = ownership
        self.rule = rule
        self.evidence = evidence
    }
}

/// Marketplace source kinds. Unknown values are kept as `.other` and treated as read-only.
public enum MarketplaceSource: Sendable, Equatable, Codable {
    case github, git, url, directory, file, claudeai
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "github": self = .github
        case "git": self = .git
        case "url": self = .url
        case "directory": self = .directory
        case "file": self = .file
        case "claudeai", "claude.ai": self = .claudeai
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .github: "github"
        case .git: "git"
        case .url: "url"
        case .directory: "directory"
        case .file: "file"
        case .claudeai: "claudeai"
        case .other(let value): value
        }
    }

    public var isLocal: Bool { self == .directory || self == .file }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct MarketplaceRecord: Codable, Sendable, Equatable {
    public let name: String
    public let source: MarketplaceSource
    /// Folder of a `directory` marketplace, or the local clone of a remote one.
    public let path: String?

    public init(name: String, source: MarketplaceSource, path: String? = nil) {
        self.name = name
        self.source = source
        self.path = path
    }
}

/// One installed plugin as reported by `claude plugin list --json` [V `plugins/cli-reference`].
public struct PluginRecord: Codable, Sendable, Equatable {
    public let id: String
    public let installPath: String
    public let readFromFolder: String?
    public let version: String?
    public let scope: String?
    public let enabled: Bool?
    public let projectPath: String?

    public init(
        id: String,
        installPath: String,
        readFromFolder: String? = nil,
        version: String? = nil,
        scope: String? = nil,
        enabled: Bool? = nil,
        projectPath: String? = nil
    ) {
        self.id = id
        self.installPath = installPath
        self.readFromFolder = readFromFolder
        self.version = version
        self.scope = scope
        self.enabled = enabled
        self.projectPath = projectPath
    }

    /// Plugin name (part before the last `@`), or the whole id when there is no origin.
    public var name: String {
        guard let at = id.lastIndex(of: "@"), at != id.startIndex else { return id }
        return String(id[..<at])
    }

    /// Origin (part after the last `@`): a marketplace name or `synced`, `skills-dir`, `inline`.
    public var origin: String? {
        guard let at = id.lastIndex(of: "@"), at != id.startIndex else { return nil }
        let origin = id[id.index(after: at)...]
        return origin.isEmpty ? nil : String(origin)
    }
}
