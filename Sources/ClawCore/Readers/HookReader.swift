import Foundation

/// One hook handler reduced to what the UI may show. The full command is never kept.
public struct HookRecord: Sendable, Equatable {
    public let event: String
    public let matcher: String?
    /// `command`, `http`, `mcp_tool`, `prompt`, `agent` [V `hooks`].
    public let handlerType: String
    /// Executable basename, URL host, or the handler type.
    public let summary: String
    public let file: String
    public let groupIndex: Int
    public let handlerIndex: Int
    /// What `HookHealth` found; empty when it was not asked for or found nothing (M2.15).
    public var health: [Problem] = []

    /// Events that can block or approve tool use. Removing such a hook changes safety behaviour.
    public var isGuard: Bool { event == "PreToolUse" || event == "PermissionRequest" }
}

public enum HookReader {
    /// Parses `{ "<Event>": [ { "matcher": "…", "hooks": [ { "type": "command", … } ] } ] }`.
    /// With `health`, each record also carries the result of `HookHealth.check`.
    public static func parse(
        _ hooks: JSONValue?, file: String, health: HookHealth.Context? = nil
    ) -> ([HookRecord], [Problem]) {
        guard let hooks else { return ([], []) }
        guard let events = hooks.objectValue else {
            return ([], [Problem(.warning, "`hooks` is not an object; it was ignored", file: file)])
        }
        var records: [HookRecord] = []
        var problems: [Problem] = []
        for event in events.keys.sorted() {
            guard let groups = events[event]?.arrayValue else {
                problems.append(Problem(.warning, "Hooks for \(event) are not a list; ignored", file: file))
                continue
            }
            for (groupIndex, group) in groups.enumerated() {
                let handlers = group["hooks"]?.arrayValue ?? []
                for (handlerIndex, handler) in handlers.enumerated() {
                    let type = handler["type"]?.stringValue ?? "command"
                    let summary: String
                    switch type {
                    case "command":
                        summary = handler["command"]?.stringValue.map(CommandSummary.executable) ?? "command"
                    case "http":
                        summary = handler["url"]?.stringValue.flatMap { URLComponents(string: $0)?.host } ?? "http"
                    default:
                        summary = type
                    }
                    var record = HookRecord(
                        event: event, matcher: group["matcher"]?.stringValue, handlerType: type, summary: summary,
                        file: file, groupIndex: groupIndex, handlerIndex: handlerIndex)
                    if let health {
                        record.health = HookHealth.check(
                            event: event, matcher: record.matcher, handler: handler, context: health)
                    }
                    records.append(record)
                }
            }
        }
        return (records, problems)
    }
}
