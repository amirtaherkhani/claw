import Foundation
import Testing

@testable import ClawCore

/// M4.7 (FR-F17-*): after Apply, every change says when a running Claude Code sees it, grouped the way
/// TECHNICAL-DESIGN section 3.4 lists them, with the command to copy where one helps. Claw never types into a
/// session.
@Suite("After-apply guidance")
struct AfterApplyGuidanceTests {
    static func outcome(_ kind: ApplyOutcome.Kind, _ changes: [(String, PlanEffect)]) -> ApplyOutcome {
        let state: ApplyOutcome.Change.State = kind == .applied ? .applied : .undone
        return ApplyOutcome(
            kind: kind, headline: "", detail: nil, backupId: "b",
            changes: changes.map {
                ApplyOutcome.Change(
                    id: $0.0, title: $0.0, state: state, guidance: state == .applied ? $0.1.guidance : nil,
                    effect: $0.1)
            },
            kept: [], notes: [], staleFile: nil)
    }

    @Test("Changes are grouped by when they take effect, in the order a person acts on them")
    func groups() {
        let guidance = AfterApplyGuidance.make(
            Self.outcome(
                .applied,
                [
                    ("Disable kit", .reloadPlugins), ("Disable tidy", .live), ("Exclude CLAUDE.md", .afterClear),
                    ("Disable db", .newSession), ("Disable notes", .live),
                ]))
        #expect(guidance.groups.map(\.effect) == [.live, .reloadPlugins, .afterClear, .newSession])
        #expect(guidance.groups.first?.changes == ["Disable tidy", "Disable notes"])
        #expect(guidance.groups.first { $0.effect == .reloadPlugins }?.copy == "/reload-plugins")
        #expect(guidance.groups.first { $0.effect == .afterClear }?.copy == "/clear")
        #expect(guidance.groups.first { $0.effect == .live }?.copy == nil)
        #expect(guidance.groups.first { $0.effect == .newSession }?.detail.contains("keeps") == true)
        #expect(guidance.needsAction)
    }

    @Test("Only applied changes get guidance; live-only changes need no action")
    func onlyApplied() {
        #expect(AfterApplyGuidance.make(Self.outcome(.rolledBack, [("Disable kit", .reloadPlugins)])).groups.isEmpty)
        let live = AfterApplyGuidance.make(Self.outcome(.applied, [("Disable tidy", .live)]))
        #expect(live.groups.count == 1)
        #expect(!live.needsAction)
    }

    @Test("A real Apply records each change's effect")
    func effectRecorded() throws {
        let review = Review(
            entries: [
                ReviewEntry(
                    id: "a", itemId: "a", concept: .plugins, title: "Disable kit", files: [], moves: [], commands: [],
                    stash: nil, notes: [], effect: .reloadPlugins, error: nil)
            ], plans: [], backupFolder: "", checklist: [], needsReloadPlugins: true)
        let subjects = review.entries.map { ApplyOutcome.Subject(id: $0.id, title: $0.title, effect: $0.effect) }
        #expect(subjects.first?.effect == .reloadPlugins)
    }
}
