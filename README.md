# Claw

A native macOS app to see, enable, disable, add and remove everything that extends Claude Code: plugins, skills, commands, rules, subagents, MCP servers and hooks. It shows who owns each item (**Yours**, **Read-only**, **Needs attention**) and offers Edit only on items you own.

> Status: **M1 done, M3 UI written (read-only).** Claw scans all seven concepts and explains who owns each item. The SwiftUI app has every prototype screen; changes can be queued and previewed, but Apply, Restore and Install stay disabled until the safe write pipeline (M2, M5). The SwiftUI code has not been compiled on macOS yet.

## Requirements

- macOS 26 or later for the app; Xcode 26 or later (Swift 6.2+). See [ADR-0005](docs/adr/0005-minimum-versions.md).
- Claude Code installed (`claude` on `PATH`, or in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). Without it Claw still reads settings files, marked as a partial scan.

## Build and run

```sh
swift build                 # core, CLI and (on macOS) the app
swift test                  # Swift Testing suites
swift run claw scan         # text summary of this Mac
swift run claw scan --json  # full result; secrets are never included
swift run claw scan --folder ~/Documents/GitHub/some-project
swift run claw scan --all-projects             # plus registered projects and those in ~/.claude.json
swift run claw list --concept hooks --bucket yours
swift run claw projects add ~/Documents/GitHub/some-project   # Claw's own list, not Claude's config
swift run ClawApp           # SwiftUI window (macOS only); Cmd-R scan, Cmd-. stop
```

Format check: `swift format lint --strict --recursive Sources Tests Package.swift`

## Layout

| Path | What |
| :- | :- |
| `Sources/ClawCore` | UI-free library: models, settings loader, readers, classifier, effective state, scanner, redaction |
| `Sources/claw` | Command line front end |
| `Sources/ClawApp` | SwiftUI shell (macOS only) |
| `Tests/ClawCoreTests` | Tests with an in-memory file system and a fake `claude` runner |
| `docs/` | Overview, PRD, technical design, roadmap, ADRs, spikes, environment |

## Docs

Start with [docs/OVERVIEW.md](docs/OVERVIEW.md). Requirements: [PRD](docs/PRD.md). Design: [TECHNICAL-DESIGN](docs/TECHNICAL-DESIGN.md). Plan: [ROADMAP](docs/ROADMAP.md). Decisions: [docs/adr](docs/adr).

## License

GPL-3.0. See [LICENSE](LICENSE).
