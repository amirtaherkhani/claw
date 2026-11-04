# Environment

Record of the tool versions the project was built and tested with. No paths that reveal secrets.

## Cloud development container (M0/M1, 2026-11-04)

| Tool | Version | Verified how |
| :- | :- | :- |
| OS | Ubuntu 24.04.5 LTS, x86_64, 2 cores | `/etc/os-release`, `nproc` |
| Swift | 6.4.2 (`swift-6.4.2-RELEASE`), from download.swift.org | `swift --version` |
| swift-format | 6.4.2 (bundled with the toolchain) | `swift format --version` |
| Claude Code | 2.1.317 | `claude --version` (used for the `claw scan` smoke test) |

Not available there: macOS, Xcode, SwiftUI. `ClawApp` has not been compiled yet.

## Owner's Mac (fill in during M0.2)

| Tool | Version |
| :- | :- |
| macOS | `sw_vers -productVersion` → … |
| Xcode | `xcodebuild -version` → … |
| Swift | `swift --version` → … |
| Claude Code | `claude --version` → … |

## CI

| Job | Image or runner | Status |
| :- | :- | :- |
| Linux core | `swift:6.4.2-noble` container | Tag exists on Docker Hub [V, checked 2026-11-04] |
| macOS | `macos-26` runner | GA on GitHub-hosted runners since 2026-02-26 [V, GitHub changelog]. Which Xcode it selects by default: check the first run's "Versions" step |
