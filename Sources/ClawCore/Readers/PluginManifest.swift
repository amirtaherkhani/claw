import Foundation

/// Where a plugin's `.claude-plugin/plugin.json` says its components are [V `plugins/manifest-reference`]. These add
/// to the standard folders [A]. Each value is a path relative to the plugin, or a list of them; a path that is
/// absolute or climbs out of the plugin is dropped with a problem.
struct PluginManifest: Sendable {
    let file: String
    var skills: [String] = []
    var commands: [String] = []
    var agents: [String] = []
    var hookFiles: [String] = []
    var mcpFiles: [String] = []
    /// Hooks written in the manifest itself.
    var inlineHooks: JSONValue?
    var problems: [Problem] = []

    init(root: String, fileSystem fs: any ReadonlyFileSystem) {
        file = joinPath(root, ".claude-plugin", "plugin.json")
        guard let data = try? fs.readFile(file), let value = try? JSONValue.parse(data) else { return }
        skills = paths(value["skills"], root: root)
        commands = paths(value["commands"], root: root)
        agents = paths(value["agents"], root: root)
        hookFiles = paths(value["hooks"], root: root)
        mcpFiles = paths(value["mcpServers"], root: root)
        if let hooks = value["hooks"], hooks.objectValue != nil { inlineHooks = hooks["hooks"] ?? hooks }
    }

    private mutating func paths(_ value: JSONValue?, root: String) -> [String] {
        let listed = value?.stringValue.map { [$0] } ?? value?.arrayValue?.compactMap(\.stringValue) ?? []
        return listed.compactMap { raw in
            let parts = raw.split(separator: "/").filter { $0 != "." }
            guard !raw.hasPrefix("/"), !parts.contains("..") else {
                problems.append(Problem(.warning, "Manifest path leaves its plugin; it was skipped: \(raw)", file: file))
                return nil
            }
            return parts.reduce(root) { joinPath($0, String($1)) }
        }
    }
}
