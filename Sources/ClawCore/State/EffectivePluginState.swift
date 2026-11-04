import Foundation

/// Sources of `enabledPlugins`, lowest to highest precedence [V `plugins/loading`].
public enum PluginSource: String, Codable, Sendable, CaseIterable {
    case addDir = "add-dir"
    case user, project, local, flag, managed

    /// Settings scope to plugin source.
    public init(_ scope: SettingsScope) {
        switch scope {
        case .managed: self = .managed
        case .local: self = .local
        case .project: self = .project
        case .user: self = .user
        }
    }
}

public struct PluginLayer: Sendable, Equatable {
    public let source: PluginSource
    public let file: String?
    public let enabledPlugins: [String: Bool]

    public init(source: PluginSource, file: String? = nil, enabledPlugins: [String: Bool]) {
        self.source = source
        self.file = file
        self.enabledPlugins = enabledPlugins
    }
}

public struct EffectiveState: Sendable, Equatable {
    public struct Override: Sendable, Equatable {
        public let source: PluginSource
        public let value: Bool
    }

    public let enabled: Bool
    public let decidedBy: PluginSource?
    public let file: String?
    /// Lower-precedence layers that disagree with the winner (for "still loads" warnings).
    public let overridden: [Override]
}

public enum EffectivePluginState {
    /// The highest-precedence source that mentions `id` wins. `add-dir` only counts when `true`.
    public static func resolve(_ id: String, layers: [PluginLayer], fallback: Bool = false) -> EffectiveState {
        var enabled = fallback
        var decidedBy: PluginSource?
        var file: String?
        var seen: [EffectiveState.Override] = []

        for source in PluginSource.allCases {
            for layer in layers where layer.source == source {
                guard let value = layer.enabledPlugins[id] else { continue }
                if source == .addDir && !value { continue }
                seen.append(.init(source: source, value: value))
                enabled = value
                decidedBy = source
                file = layer.file
            }
        }
        return EffectiveState(
            enabled: enabled, decidedBy: decidedBy, file: file,
            overridden: seen.filter { $0.value != enabled })
    }
}
