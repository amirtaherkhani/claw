# Next steps (handoff for Claude Code)

Status on 2026-11-05. Start here when you continue in Claude Code on the Mac. Read `CLAUDE.md` first; this file says where things stand and what to do next.

## Where it stands

| Milestone | State |
| :- | :- |
| M0 Foundations | Done. S1 to S4 and S6 to S9 verified and reviewed. S5 and S10 partial: they need a Mac with a managed profile and a fresh user account |
| M1 Core read-only | Done: all seven concepts, ownership rules, effective state, projects, progress and Stop, CLI. Exit criteria reported in the M1 close-out |
| M2 Safe write pipeline | **In progress.** M2.1 to M2.13 merged (#22 to #36); the owner added M2.14 to M2.16 (decisions in the M2 close-out below) |
| M3 GUI read-only | Screens done and compared with `docs/design/` on the Mac; text in a String Catalog, XCUITest smoke tests and accessibility audit added. Open: your review of the M3 exit criteria |
| M4 to M7 | Not started |

Code: `amirtaherkhani/claw`, `main`, CI green on Linux and macOS.

## M2 close-out (2026-11-10)

| Exit criterion | Shown by | State |
| :- | :- | :- |
| NFR-SAFE-1: a failed or interrupted Apply leaves each file fully old or fully new | `ApplyTests` crash and fault at every step, `AtomicWriteTests`, `RecoveryKillTests` (real SIGKILL of `claw` at each step, M2.16) | Met |
| NFR-SAFE-2: unknown keys, order, indentation and trailing newline kept | `JSONEditTests` (600 seeds), plan goldens | Met |
| NFR-SAFE-3: no hard delete | `NoHardDeleteTests` (M2.13) | Met |
| NFR-SAFE-4: backup before every write, verify after | `ApplyTests` | Met |
| Contract tests green | `ContractTests` on the owner's Mac (Claude Code 2.1.319) and on CI (`contract.yml`, nightly) | Met |
| `FR-F15-*` round trip | `HookStashTests`, `RestoreTests`, `NoHardDeleteTests`, `StashedHookListTests` | **Partial**: FR-F15-4 done in M2.14; FR-F15-6 (detect the reload) is not built |
| Dry-run output equals the real diff | `WriteCommandsTests` (one renderer) | Met |

Owner decisions (2026-11-10): M2 stays open for three more tasks, in this order.

- **M2.14, stashed hooks:** a hook Claw turned off stays in the Hooks list as "Off (turned off by Claw)", with a switch to turn it back on.
- **M2.15, hook health check:** each hook is checked without running it (event name, type, matcher, script found, script runnable, timeout) and shows OK, ⚠️ or ❌ with a short reason. Hooks turned off by Claw are checked too. Whether the Claude desktop app shows a hook status, and how, is [U]: a spike compares the two.
- **M2.16, recovery:** at the next launch after a crash, Claw shows what step the change reached:

  | Crash during | Notification | Cancel | Continue |
  | :- | :- | :- | :- |
  | 1. Backup | "The last change didn't finish." | Drop the backup; nothing changed | Back up, write, verify, finish |
  | 2. Write | "The last change didn't finish." | Put the old files back | Finish the write, verify, finish |
  | 3. Verify | "The last change wasn't checked." | Put the old files back | Check again, finish |
  | 4. Finish | "The last change was done." | OK only | |

  Continue is refused when a file was changed by another program after the crash; only Cancel is offered then.

Open after M2, for the owner to order:

1. ~~FR-F15-4: the scanner should read the hook stash and list its entries as Disabled (app-managed).~~ M2.14.
2. ~~The app and `claw` still build `ClaudeCLI` without an environment; switch them to `ClaudeCLI(executable:environment:)` (M2.12).~~ Done in M2.16.
3. A restore does not undo CLI steps (`plugin uninstall`, `mcp remove`); the manifest does not record them yet.
4. ~~Start-up recovery: nothing calls `BackupStore.interrupted()` and `rollBack(id:stash:)` at launch yet.~~ M2.16.
5. TECHNICAL-DESIGN 9.5 needs the stash entry fields and the kept original settings file.

## Open before M2

1. S5 and S10 stay partial; the owner chose on 2026-11-05 not to let them block M2.

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
| FR-F02-2 walk | A folder scan also reads nested `.claude/` folders: depth 4, ignored folders, 5,000 directories or 2 s, and a note when cut short | #13 | 2026-11-05 |
| M1.5 manifest paths | Custom `skills`, `commands`, `agents`, `hooks` and `mcpServers` in `plugin.json`; absolute and `..` paths are refused with a problem | #14 | 2026-11-05 |
| M3.9 | All `ClawApp` text in `Localizable.xcstrings`, generated by `scripts/sync-strings.sh` from what the compiler finds | #15 | 2026-11-05 |
| Scan target | The Scan page follows the real target, so a scan started from a project row no longer says This Mac | #16 | 2026-11-05 |
| M3.10 | Xcode project from `project.yml` (ADR-0006), XCUITest smoke tests on a fake HOME, audit on every page, CI job; two controls and two groups got accessibility labels | #17 | 2026-11-05 |
| M0.6 | Spikes S1 to S4 and S6 to S9 verified in throwaway folders; S5 and S10 partial; six follow-up changes listed | #18 | 2026-11-05 |
| S8, F11 | `.claude.json` follows `CLAUDE_CONFIG_DIR` even when it names `~/.claude`; missing files under `/private` no longer look like links leaving the root | #19 | 2026-11-05 |
| S1, S7 | `.mcp.json` servers read every disable source, including `/mcp disable` and the project entry of `.claude.json` | #20 | 2026-11-05 |
| M0.8 | [U] tags, TD 3.4, the M2.5 row and ADR-0004 updated from the spike results | #21 | 2026-11-05 |
| M2.1 | `JSONEdit`: set, remove and array insert as one byte-range edit; 600-seed property tests | #22 | 2026-11-05 |
| M2.2 | `AtomicWrite` with the stale-hash check, link and mode handling; SHA-256 in pure Swift, no dependency | #23 | 2026-11-05 |
| M2.3 | Backup store: private folders, `manifest.json` saved at each step, originals under `files/`, moves under `removed/` with their modes | #24 | 2026-11-05 |
| M2.4 | `history.jsonl`; recovery of an `in-progress` backup from every step of an Apply, leaving anything someone else changed | #25 | 2026-11-05 |
| M2.5 | Planner for `setEnabled`: exact before and after bytes per concept, `unknown` controls refused; three controls verified from S1, S2, S7 | #26 | 2026-11-05 |
| M2.6 | Planner for removal: CLI uninstall keeps data, files move to backup, `.mcp.json` edit or `mcp remove`, hooks checked against the scan; FR-F08 warnings | #28 | 2026-11-05 |
| M2.7 | Hook stash: put keeps the handler and group as written, take puts them back in place or recreates the group; an identical handler is a no-op | #29 | 2026-11-05 |
| M2.8 | Override detection: a higher scope that defeats a change warns in Claude Code's words; a list in another file keeps an item off; managed settings refuse | #30 | 2026-11-05 |
| M2.9 | Apply: stale check, backup, moves, writes, CLI, verify, rollback; a fault or a crash at each of 7 steps leaves the old files; `.claude.json` is planned again up to three times | #31 | 2026-11-05 |
| M2.10 | Restore: `Restorer.plan` returns the changes that put a backup back, with conflicts for anything changed since; apply then restore is byte-identical, modes included | #33 | 2026-11-09 |
| M2.11 | CLI `claw plan`, `apply [--dry-run]`, `restore [--accept]`, `history` on `WriteCommands`; the dry run prints what plan prints; diffs are masked JSON or sizes only; a restore with changed files is refused until `--accept` | #34 | 2026-11-10 |
| M2.12 | Contract tests against real `claude` (2.1.319) in a temp `HOME` and `CLAUDE_CONFIG_DIR`: disable, enable, restore, dry run and remove agree with `plugin list --json`; nightly macOS job `contract.yml`. Fix: `claude` now gets `HOME`, `CLAUDE_CONFIG_DIR` and the plugin cache from the environment Claw reads (`ClaudeCLI(executable:environment:)`), before it inherited the parent process's | #35 | 2026-11-10 |
| M2.13 | No hard delete: `Disk` is the only `rename`/`unlink` in the write layer; a guard watches apply, restore, failure and crash recovery at every step (also on the pipeline's own threads) and flags any delete or overwrite of a user file; a source check stops calls around `Disk` | #36 | 2026-11-10 |
| M2.14 | Stashed hooks in the list: the scanner reads Claw's stash and lists each hook Off, "turned off by Claw", Personal, with a switch; turning it on plans the restore (FR-F15-4) | #38 | 2026-11-10 |
| M2.15 | Hook health check: each hook is checked without running it (event, type and its field, matcher pattern, script found, script runnable unless given to an interpreter, timeout); errors and warnings name the script, never its arguments; the app's detail shows them. Spike S15 (desktop app) open | #39 | 2026-11-10 |
| M2.16 | Recovery with Cancel and Continue: an interrupted change is reported by the step it reached (backup, write, verify, finish); Cancel rolls back, Continue checks again (verify) or undoes and repeats the request saved as `intent` (backup, write), OK records a finished one; Continue is refused for files changed elsewhere; `claw recover`; the real `claw` binary is killed with SIGKILL at each step in tests. `claw` and the app pass the environment to `claude` | #40 | 2026-11-10 |

## Known gaps and decisions to revisit

- Overview "changes applied · 7 days" and the backup card show placeholders until M2.
- The app uses the system font instead of DM Sans [A]; change `Theme.swift` if you want DM Sans (bundle it, check the licence).
- Accent is a hex value in code; move it to an `AccentColor` asset now that the Xcode app target exists (M6).
- The scan runs only on demand; there is no file watching yet.
- `swift run ClawApp` has no bundle ID, so UI automation cannot target it, and a rebuilt ad-hoc bundle counts as a new app for privacy prompts. For visual checks, wrap the binary in a scratch `.app` and set `HOME` to a temporary folder with sample config.
- Name risk: "Claw" vs the OpenClaw project (ADR-0002). Check before a public release.
- Project keys in `.claude.json` are real paths (S1), but Claw looks them up as written, so a project registered through a symlink misses its entry.
- Stop keeps finished steps only. A stopped scan that found items replaces the list (FR-F02-3), so later concepts disappear and every Modified date goes blank until the next full scan. One that found nothing leaves the previous scan on screen (`ScanOutcome`).
- Only a complete scan prunes the queue (`ScanOutcome`). Without the `claude` CLI every scan is partial, so a change whose item was deleted stays in Review until it is discarded. M2's stale check must refuse such a change at Apply.
- A complete scan prunes only changes on items it covers (`ScanOutcome`): a project item needs that project read, anything else needs a Mac scan. So a change stays in Review until it is discarded when its folder is no longer scanned (deleted, unregistered, or reached by another path spelling, since paths are compared as written). A folder scan also ignores the plugins and user-level hooks it lists, so a change on a deleted one waits for a Mac scan. M2's stale check must refuse these at Apply too.
- A thread abandoned by Stop stays blocked until the dialog is answered, and scanning again blocks a new thread on the same file. One thread per press, ended by answering the dialog.
- Disk calls outside a scan still run on the main actor: `ProjectInspection.inspect` in view bodies and `AppModel.loadProjects`. Listing a protected folder there could hang the window (F9).
- Items in nested folders carry their own `projectPath`, so a queued change on one is never pruned by a scan of the parent folder (`ScanOutcome` gets only the scanned folder). It stays in Review until discarded.
- Manifest paths add to the standard folders [A]: no plugin on the owner's Mac uses a non-standard path, so this comes from the docs and fixtures only.
- Managed skills are not read (M1.6); the enterprise skills path waits for S10.
- `BlockedReadTests` "Reads run on a dedicated thread" failed once on Linux CI (#24) and passed on rerun, in code that PR did not touch. Cause not found; the test logs `Thread.current.name`.
- To accept a scan change on purpose: `CLAW_UPDATE_GOLDENS=1 swift test --filter GoldenTests`, then review the diff in `Tests/Goldens`.
- SwiftUI looks up text in `Bundle.main`, but SwiftPM puts the catalog in a separate resource bundle, so `swift run ClawApp` shows the English keys and never reads the catalog. A bundled app does read it: checked by placing strings in the scratch `.app`. The Xcode app target includes it.
- Text from `ClawCore` stays English, outside the catalog: concept and owner names, `counted(_:_:)` plurals, headlines, problem messages. Translating it needs a key-based API (M6.6).
- After changing UI text, run `scripts/sync-strings.sh` (macOS). Nothing fails when it is forgotten: a new string just shows its English key.

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
