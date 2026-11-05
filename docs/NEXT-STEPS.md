# Next steps (handoff for Claude Code)

Status on 2026-11-05. Start here when you continue in Claude Code on the Mac. Read `CLAUDE.md` first; this file says where things stand and what to do next.

## Where it stands

| Milestone | State |
| :- | :- |
| M0 Foundations | Done. Open: M0.6 (spikes S1 to S10), M0.8 (update [U] tags from spike results) |
| M1 Core read-only | Done: all seven concepts, ownership rules, effective state, projects, progress and Stop, CLI. Open: the nested walk and manifest path gaps under Known gaps |
| M2 Safe write pipeline | **Next.** Nothing started |
| M3 GUI read-only | Screens done and compared with `docs/design/` on the Mac. Open: XCUITest smoke tests, accessibility audit, String Catalog |
| M4 to M7 | Not started |

Code: `amirtaherkhani/claw`, `main`, CI green on Linux and macOS.

## Open before M2

1. The M1 gaps under Known gaps: nested walk, custom manifest paths.
2. The spikes below, each in a throwaway config directory, with the owner reviewing the results.

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
| Loop | `roadmap-loop` skill and CLAUDE.md rule | #2 | 2026-11-04 |
| M0.2, M3 visual check | First Mac session: versions recorded, icon rail and Go menu, layout fix, button hierarchy, plurals | #3 | 2026-11-04 |
| Close-out | `roadmap-loop` step 10: merge finished branches and remove merged ones after each section | #6 | 2026-11-05 |
| F9 | Stop returns during a blocked read; reads leave the concurrency pool; `ScanView` says when macOS may be waiting for a prompt | #4 | 2026-11-04 |
| Stop keeps the queue | `ScanOutcome` in `ClawCore`: only a complete scan prunes the queue, and a stopped scan that found nothing leaves the previous scan on screen | #5 | 2026-11-04 |
| Scan coverage keeps the queue | `ScanOutcome` prunes a change only if the scan covered its item: a folder scan counts for that folder, a Mac scan for what it read. A plugin declared only in a project's settings now belongs to that project | #8 | 2026-11-05 |
| M1.14 | Fake HOME on a real disk with a symlinked dotfile, hostile ids and a managed layer; golden `ScanResult` for This Mac, one folder and no CLI in `Tests/Goldens` | #9 | 2026-11-05 |
| FR-F02-2 scope | A folder scan lists only that folder's project and local items; other scopes still decide their state | #10 | 2026-11-05 |
| M1.15 | Compared with Claude Code for the `claw` project (`docs/compare-m1.md`); plugin MCP servers at the top level of `.mcp.json` or in `plugin.json`, and a plugin root `SKILL.md`, are now read | #11 | 2026-11-05 |
| FR-F02-5 | `ContainedFileSystem` keeps every scan read inside its root and reports refused links; a plugin with no install path is no longer read at the disk root | #12 | 2026-11-05 |

## Known gaps and decisions to revisit

- Overview "changes applied · 7 days" and the backup card show placeholders until M2.
- The app uses the system font instead of DM Sans [A]; change `Theme.swift` if you want DM Sans (bundle it, check the licence).
- Accent is a hex value in code; move it to an `AccentColor` asset when the Xcode app target is added (M6).
- The scan runs only on demand; there is no file watching yet.
- `swift run ClawApp` has no bundle ID, so UI automation cannot target it, and a rebuilt ad-hoc bundle counts as a new app for privacy prompts. For visual checks, wrap the binary in a scratch `.app` and set `HOME` to a temporary folder with sample config.
- Name risk: "Claw" vs the OpenClaw project (ADR-0002). Check before a public release.
- `known_marketplaces.json` nesting and `~/.claude.json` paths are assumptions until S1 and S3.
- Stop keeps finished steps only. A stopped scan that found items replaces the list (FR-F02-3), so later concepts disappear and every Modified date goes blank until the next full scan. One that found nothing leaves the previous scan on screen (`ScanOutcome`).
- Only a complete scan prunes the queue (`ScanOutcome`). Without the `claude` CLI every scan is partial, so a change whose item was deleted stays in Review until it is discarded. M2's stale check must refuse such a change at Apply.
- A complete scan prunes only changes on items it covers (`ScanOutcome`): a project item needs that project read, anything else needs a Mac scan. So a change stays in Review until it is discarded when its folder is no longer scanned (deleted, unregistered, or reached by another path spelling, since paths are compared as written). A folder scan also ignores the plugins and user-level hooks it lists, so a change on a deleted one waits for a Mac scan. M2's stale check must refuse these at Apply too.
- A thread abandoned by Stop stays blocked until the dialog is answered, and scanning again blocks a new thread on the same file. One thread per press, ended by answering the dialog.
- Disk calls outside a scan still run on the main actor: `ProjectInspection.inspect` in view bodies and `AppModel.loadProjects`. Listing a protected folder there could hang the window (F9).
- A folder scan has no bounded walk for nested `.claude/` folders yet (FR-F02-2, TD 8.2).
- Custom paths in `plugin.json` (`skills`, `commands`, `agents`, a path in `mcpServers`) are not read (M1.5); only the standard folders and inline `mcpServers` are.
- Managed skills are not read (M1.6); the enterprise skills path waits for S10.
- To accept a scan change on purpose: `CLAW_UPDATE_GOLDENS=1 swift test --filter GoldenTests`, then review the diff in `Tests/Goldens`.

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
