# CLAUDE.md: Claw

Native macOS app (Swift 6, SwiftUI) that manages Claude Code plugins, skills, commands, rules, subagents, MCP servers and hooks. Read `docs/OVERVIEW.md` first; requirements are in `docs/PRD.md`, design in `docs/TECHNICAL-DESIGN.md` (its TypeScript blocks are the behaviour spec, see ADR-0001), plan in `docs/ROADMAP.md`. **Current state and the next tasks: `docs/NEXT-STEPS.md`.** UI design (prototype boards, tokens, board-to-code map): `docs/design/README.md`.

## Project facts

- Build: `swift build` · Test all: `swift test` · Test one: `swift test --filter <SuiteOrTestName>`
- Format check: `swift format lint --strict --recursive Sources Tests Package.swift` (fix with `swift format --in-place --recursive Sources Tests Package.swift`)
- Run: `swift run claw scan [--json] [--folder <path>] [--no-cli]` · App (macOS): `swift run ClawApp`
- Layout: `Sources/ClawCore` (no UI; must build on Linux), `Sources/claw` (CLI), `Sources/ClawApp` (SwiftUI, macOS only), `Tests/ClawCoreTests`
- No third-party dependencies. Adding one needs an ADR.
- Gotchas: Foundation on Linux differs from macOS (see `docs/spikes.md` F1 to F4). Blocking work never runs on `DispatchQueue.global()`; use a dedicated thread. Config JSON is parsed through `JSONValue.parse` (strict).

## Rules for this repo

- Scanning is read-only by construction: readers take a `ReadonlyFileSystem`; do not add write methods to it.
- Every write (from M2) goes through the pipeline in `docs/TECHNICAL-DESIGN.md` section 9: plan, diff, backup, atomic write, verify, history. Never hard-delete.
- Unknown ownership means Read-only. Never show Edit on an item you cannot prove is Personal.
- Never print, log or store secret values: pass MCP `env`, `headers` and URLs through `Redactor`.
- Never run `claude` through a shell; use `ClaudeCLI` (argument vector, name validation, timeout).
- Test against temporary config directories, never the real `~/.claude`.
- SwiftUI: system components first; glass only on controls and navigation; check with the `liquid-glass` skill linter.
- Mark anything unverified with [U] and link the spike in `docs/spikes.md`.
- Work on a branch; the default branch is changed only through pull requests.

## Development loop

- To continue the roadmap, use the `roadmap-loop` skill (`.claude/skills/roadmap-loop/SKILL.md`): one task per branch and PR, test first, local checks, CI green, then `gh pr merge --squash --delete-branch`, then the next task.
- Merging is allowed only through that skill's merge gate. Its stop conditions (real config, unverified controls, dependencies, public model changes, visual review, release work, repeated CI failures, end of milestone) always mean: stop and ask.
- Record every finished task in the Task log of `docs/NEXT-STEPS.md`.
