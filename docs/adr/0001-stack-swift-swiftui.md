# ADR-0001: Swift and SwiftUI instead of TypeScript and Electron

- **Status:** Accepted (2026-11-04, decided by the project owner)
- **Supersedes:** the stack recommendation in `TECHNICAL-DESIGN.md` section 2 (TypeScript core, Electron + React shell)
- **Closes:** OQ-1

## Context

The docs recommended a TypeScript core with an Electron shell. The owner chose Swift and SwiftUI. The design asks for the macOS 26/27 look with Liquid Glass, which only native SwiftUI or AppKit renders; a web shell can only imitate it.

## Decision

One Swift package, Swift 6 language mode:

| Target | Platforms | Purpose |
| :- | :- | :- |
| `ClawCore` (library) | macOS, Linux | Scan, classify, effective state, CLI adapter, later the write pipeline. Foundation only, no UI, no third-party dependencies |
| `claw` (executable) | macOS, Linux | Command line front end; delivers value and tests before the GUI |
| `ClawApp` (executable) | macOS 26+ | SwiftUI shell. Declared only when the manifest is evaluated on macOS |
| `ClawCoreTests` | macOS, Linux | Swift Testing suites |

An Xcode app target (bundle, entitlements, signing, notarization) is added in M6. Until then `swift run ClawApp` starts the window.

## Consequences

- Real Liquid Glass from system components; no custom glass on content (see the `liquid-glass` skill rules).
- The TypeScript code in `TECHNICAL-DESIGN.md` stays as the behaviour spec. Each port keeps the same tests.
- No `jsonc-parser`: the minimal-diff JSON editor for M2 must be written in Swift (byte-range edits over the strict scanner in `JSONValue.swift`).
- Foundation on Linux differs from macOS. Found during M1 and handled:
  - `JSONDecoder` accepts trailing commas on Linux, so `StrictJSON.validate` runs first.
  - A child started from a concurrency-pool thread inherited a blocked signal mask, so SIGTERM never arrived. Processes are now spawned from a dedicated thread with an empty mask, with a SIGKILL fallback.
  - `Process.waitUntilExit` waits for open pipes on Linux; the timeout path no longer depends on it.
- The SwiftUI target cannot be compiled on Linux. CI needs a macOS runner, and every UI change must be built on a Mac.
