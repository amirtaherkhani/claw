import Foundation

public struct PluginClassifyContext: Sendable {
    public let markets: [String: MarketplaceRecord]
    /// `true`/`false` when the marketplace entry's `source` was read; `nil` when unknown.
    public let entrySourceIsRelative: Bool?
    /// Git remote of the marketplace folder, already redacted.
    public let gitRemote: String?

    public init(markets: [String: MarketplaceRecord], entrySourceIsRelative: Bool? = nil, gitRemote: String? = nil) {
        self.markets = markets
        self.entrySourceIsRelative = entrySourceIsRelative
        self.gitRemote = gitRemote
    }
}

/// Plugin ownership rules P1 to P7 (TECHNICAL-DESIGN section 5.1). P8, declared but not installed,
/// is decided by the scanner. When ownership cannot be proven the result is read-only.
public enum PluginClassifier {
    public static func classify(_ plugin: PluginRecord, context: PluginClassifyContext) -> Classification {
        guard let origin = plugin.origin else {
            return Classification(ownership: .orphan, rule: "P1", evidence: ["id \"\(plugin.id)\" has no @origin"])
        }

        switch origin {
        case "synced":
            return Classification(ownership: .synced, rule: "P2", evidence: ["origin is synced (claude.ai account)"])
        case "skills-dir":
            return Classification(
                ownership: .personal, rule: "P3",
                evidence: ["skills-directory plugin at \(plugin.installPath)"])
        case "inline":
            return Classification(ownership: .personal, rule: "P4", evidence: ["session-only plugin (--plugin-dir)"])
        default:
            break
        }

        guard let market = context.markets[origin] else {
            return Classification(ownership: .orphan, rule: "P5", evidence: ["marketplace \"\(origin)\" is not registered"])
        }

        let loadsInPlace = plugin.readFromFolder != nil || context.entrySourceIsRelative == true
        if market.source.isLocal && loadsInPlace {
            var evidence = [
                "local \(market.source.rawValue) marketplace at \(market.path ?? "(unknown path)")",
                "loads in place, not copied to the cache",
            ]
            if let remote = context.gitRemote { evidence.append("git remote: \(remote)") }
            return Classification(ownership: .personal, rule: "P6", evidence: evidence)
        }

        let why = market.source.isLocal ? "cannot prove the plugin loads in place" : "\(market.source.rawValue) marketplace"
        return Classification(ownership: .market, rule: "P7", evidence: ["marketplace \"\(origin)\": \(why)"])
    }
}
