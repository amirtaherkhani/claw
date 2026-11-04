# Next steps (handoff for Claude Code)

Status on 2026-11-04. Start here when you continue in Claude Code on the Mac. Read `CLAUDE.md` first; this file says where things stand and what to do next.

## Where it stands

| Milestone | State |
| :- | :- |
| M0 Foundations | Done in the cloud. Open: M0.2 (record your Mac's versions in `docs/environment.md`), M0.6 (spikes S1 to S10), M0.8 (update [U] tags from spike results) |
| M1 Core read-only | Done: all seven concepts, ownership rules, effective state, projects, progress and Stop, CLI. Open: M1.14 golden fixtures, M1.15 manual comparison on the Mac |
| M2 Safe write pipeline | **Next.** Nothing started |
| M3 GUI read-only | Screens done and compiling on macOS CI. Open: visual check against `docs/design/`, XCUITest smoke tests, accessibility audit, String Catalog |
| M4 to M7 | Not started |

Code: `amirtaherkhani/claw`, PR #1 (`feat/m0-m1-foundation`), CI green on Linux and macOS (Xcode 26.6, Swift 6.3.3).

## First session on the Mac (about 30 minutes)

1. Get the code: `git clone https://github.com/amirtaherkhani/claw /Users/mac/Documents/GitHub/claw && cd /Users/mac/Documents/GitHub/claw && git checkout feat/m0-m1-foundation`
2. Check it: `swift build && swift test && swift run claw scan`
3. Run the app: `swift run ClawApp`. Walk every screen next to the boards in `docs/design/prototype` (open the Design artifact link in `docs/design/README.md`). Note what differs.
4. Fill `docs/environment.md` (macOS, Xcode, Swift, `claude --version`).
5. Compare `claw scan` with Claude Code's own views (`/plugin`, `/skills`, `/mcp`, `/hooks`, `/agents`) for one project; write differences to `docs/compare-m1.md` (M1.15).
6. Merge PR #1 when you are happy, then branch for M2: `git checkout main && git pull && git checkout -b feat/m2-write-pipeline`.

## Spikes to run before M2 writes anything

Run each in a throwaway config directory (`export CLAUDE_CONFIG_DIR="$(mktemp -d)"`), never your real `~/.claude`. Record commands, redacted output and the conclusion in `docs/spikes.md`.

| Spike | Why M2 needs it |
| :- | :- |
| S1 `~/.claude.json` structure | MCP disable for user and local servers writes there |
| S3 directory marketplace install | Decides ADR-0004 (direct `enabledPlugins` edit vs CLI) and rule P6 evidence |
| S7 `disabledMcpjsonServers` value shape | MCP disable for `.mcp.json` servers |
| S2 `skillOverrides` for commands | Whether commands can be disabled the same way as skills |
| S4, S9 live vs reload | What the "after apply" guidance says |
| S8 `CLAUDE_CONFIG_DIR` and `~/.claude.json` | Safe test isolation for contract tests |

Until a spike closes, the UI keeps showing "Not verified yet" for that control, and Apply must refuse changes whose control is `unknown`.

## M2 plan (in order)

Design: `docs/TECHNICAL-DESIGN.md` section 9. Tasks: `docs/ROADMAP.md` M2.1 to M2.13. Put new code in `Sources/ClawCore/Write/` and `Sources/ClawCore/Plan/`; keep it free of UI types and runnable on Linux.

1. **`JSONEdit.swift`**: set or remove one value by key path with byte-range edits on top of `StrictJSON`'s scanner; keep every other byte, key order, indentation and line endings. Property tests with seeded random edits (port the TypeScript tests in TD 9.1).
2. **`AtomicWrite.swift`**: temp file in the same folder, fsync, compare the scan-time SHA-256, rename; follow symlinks so the link stays a link; keep the file mode.
3. **Backup store**: `~/.claude.bak/<ISO time>/` (0700, files 0600), `manifest.json`, `removed/`; `history.jsonl`; recovery of an interrupted apply.
4. **Planner**: turn `ChangeQueue` (already in `Sources/ClawCore/Presentation/ChangeQueue.swift`) into real `PlannedChange`s with exact file diffs. The previews the UI shows today become the real diff.
5. **Apply**: stale check, backup, writes, CLI steps through `ClaudeCLI`, verify (reparse, `claude plugin list --json`), rollback on any failure.
6. **Restore** from History, through the same pipeline.
7. **Hook stash** (remove and keep a copy; restore to the same position).
8. **CLI**: `claw plan`, `claw apply --dry-run`, `claw restore`, `claw history`.
9. **UI**: enable Apply in `ReviewSheet`, fill `HistoryView`, the Overview "changes applied" and backup cards, "last backup" in the status bar.
10. **Contract tests** against the real `claude` CLI in a temporary config directory (macOS CI job, nightly).

Exit: apply then restore returns byte-identical files; fault injection at every step leaves old or new, never half; no hard delete anywhere (`NFR-SAFE-*`).

## Task log

The `roadmap-loop` skill reads this to pick the next task and appends one row per merged PR.

| Task | Summary | PR | Date |
| :- | :- | :- | :- |
| M0, M1, M3 screens | Foundation, read-only scanner and CLI, SwiftUI screens, docs and design | #1 | 2026-11-04 |
| Loop | `roadmap-loop` skill and CLAUDE.md rule | this PR | 2026-11-04 |

## Known gaps and decisions to revisit

- Overview "changes applied · 7 days" and the backup card show placeholders until M2.
- The app uses the system font instead of DM Sans [A]; change `Theme.swift` if you want DM Sans (bundle it, check the licence).
- Accent is a hex value in code; move it to an `AccentColor` asset when the Xcode app target is added (M6).
- The scan runs only on demand; there is no file watching yet.
- Name risk: "Claw" vs the OpenClaw project (ADR-0002). Check before a public release.
- `known_marketplaces.json` nesting and `~/.claude.json` paths are assumptions until S1 and S3.

## Running the loop

In Claude Code: `/roadmap-loop` (until the end of the milestone), `/roadmap-loop M2.1` (one task) or `/roadmap-loop 3` (three tasks). See `.claude/skills/roadmap-loop/SKILL.md` for the merge gate and stop conditions.

## Kickoff prompt for Claude Code (M2)

Use plan mode first; one task per commit; one milestone per branch.

```text
Read CLAUDE.md, docs/NEXT-STEPS.md and docs/TECHNICAL-DESIGN.md section 9. Implement milestone M2 from
docs/ROADMAP.md, starting with M2.1 (Sources/ClawCore/Write/JSONEdit.swift). For each task: restate the
acceptance criteria, write the failing Swift Testing test first, implement the smallest change, then run
swift build, swift format lint --strict --recursive Sources Tests Package.swift, and swift test, and report
passed, failed, skipped or not run. Never touch the real ~/.claude: use temporary directories. Stop and ask
before adding a dependency, changing a public type in ClawCore/Model, or enabling Apply for a control whose
status is unknown.
```
