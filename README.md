# Clef

A native macOS app to see, enable, disable, add and remove everything that extends Claude Code: plugins, skills, commands, rules, subagents, MCP servers and hooks. It shows who owns each item (**Yours**, **Read-only**, **Needs attention**) and offers Edit only on items you own.

> Status: **M1 in progress, read-only.** Clef scans plugins and skills today. Nothing in this version writes to your configuration.

## Requirements

- macOS 26 or later for the app; Xcode 26 or later (Swift 6.2+). See [ADR-0005](docs/adr/0005-minimum-versions.md).
- Claude Code installed (`claude` on `PATH`, or in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`). Without it Clef still reads settings files, marked as a partial scan.

## Build and run

```sh
swift build                 # core, CLI and (on macOS) the app
swift test                  # Swift Testing suites
swift run clef scan         # text summary of this Mac
swift run clef scan --json  # full result; secrets are never included
swift run clef scan --folder ~/Documents/GitHub/some-project
swift run ClefApp           # SwiftUI window (macOS only)
```

Format check: `swift format lint --strict --recursive Sources Tests Package.swift`

## Layout

| Path | What |
| :- | :- |
| `Sources/ClefCore` | UI-free library: models, settings loader, readers, classifier, effective state, scanner, redaction |
| `Sources/clef` | Command line front end |
| `Sources/ClefApp` | SwiftUI shell (macOS only) |
| `Tests/ClefCoreTests` | Tests with an in-memory file system and a fake `claude` runner |
| `docs/` | Overview, PRD, technical design, roadmap, ADRs, spikes, environment |

## Docs

Start with [docs/OVERVIEW.md](docs/OVERVIEW.md). Requirements: [PRD](docs/PRD.md). Design: [TECHNICAL-DESIGN](docs/TECHNICAL-DESIGN.md). Plan: [ROADMAP](docs/ROADMAP.md). Decisions: [docs/adr](docs/adr).

## License

Not chosen yet.
