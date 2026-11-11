import Foundation

/// What to do in Claude Code after Apply (PRD F17, ROADMAP M4.7): each applied change grouped by when a running
/// session sees it, as TECHNICAL-DESIGN section 3.4 lists it [V S4]. Claw offers the command to copy and never
/// types into a session (FR-F17-3).
public struct AfterApplyGuidance: Sendable, Equatable {
    public struct Group: Sendable, Equatable, Identifiable {
        public let effect: PlanEffect
        public let title: String
        public let detail: String
        /// The command to copy into Claude Code, when one makes the change take effect.
        public let copy: String?
        /// Titles of the changes in this group, in queue order.
        public let changes: [String]
        public var id: String { effect.rawValue }
    }

    public let groups: [Group]

    /// Something the person has to do in Claude Code: a command, or a new session.
    public var needsAction: Bool { groups.contains { $0.effect != .live } }

    /// Only applied changes; the order a person acts on them: nothing, a command, `/clear`, a new session.
    public static func make(_ outcome: ApplyOutcome) -> AfterApplyGuidance {
        let applied = outcome.changes.filter { $0.state == .applied }
        let order: [PlanEffect] = [.live, .reloadPlugins, .afterClear, .newSession]
        let groups = order.compactMap { effect -> Group? in
            let titles = applied.filter { ($0.effect ?? .newSession) == effect }.map(\.title)
            guard !titles.isEmpty else { return nil }
            return group(effect, titles)
        }
        return AfterApplyGuidance(groups: groups)
    }

    private static func group(_ effect: PlanEffect, _ changes: [String]) -> Group {
        switch effect {
        case .live:
            Group(
                effect: effect, title: "Takes effect right away",
                detail: "Claude Code watches these settings and picks the change up in open sessions.", copy: nil,
                changes: changes)
        case .reloadPlugins:
            Group(
                effect: effect, title: "Run /reload-plugins",
                detail: "Open sessions see plugin changes after /reload-plugins, or in a new session.",
                copy: "/reload-plugins", changes: changes)
        case .afterClear:
            Group(
                effect: effect, title: "Run /clear",
                detail: "Open sessions pick this up after /clear, or in a new session.", copy: "/clear",
                changes: changes)
        case .newSession:
            Group(
                effect: effect, title: "Start a new session",
                detail: "A session that is already running keeps the old setting, even after /reload-plugins.",
                copy: nil, changes: changes)
        }
    }
}
