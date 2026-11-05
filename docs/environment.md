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

## Owner's Mac (M0.2, 2026-11-04)

| Tool | Version | Verified how |
| :- | :- | :- |
| macOS | 27.2 (build 26B123), arm64 | `sw_vers`, `uname -m` |
| Xcode | 27.2 (build 27B52) | `xcodebuild -version` |
| Swift | 6.4.2 (`swiftlang-6.4.2.1.9`, `clang-2100.4.1.1`), target `arm64-apple-macosx27.2.0` | `swift --version` |
| swift-format | 6.4.4 | `swift format --version` |
| Claude Code | 2.1.316 | `claude --version` |

## CI

| Job | Image or runner | Status |
| :- | :- | :- |
| Linux core | `swift:6.4.2-noble` container | Tag exists on Docker Hub [V, checked 2026-11-04] |
| macOS | `macos-26` runner | GA on GitHub-hosted runners since 2026-02-26 [V, GitHub changelog]. Which Xcode it selects by default: check the first run's "Versions" step |
