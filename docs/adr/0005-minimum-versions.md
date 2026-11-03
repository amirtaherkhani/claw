# ADR-0005: Minimum macOS, Swift and Claude Code versions

- **Status:** Proposed (confirm on the Mac in M0.2 and spike S10)
- **Closes when accepted:** OQ-4, OQ-5

| Component | Minimum | Why |
| :- | :- | :- |
| macOS | 26 | Liquid Glass and the macOS 26 SwiftUI APIs (`glassProminent`, inspector, toolbar spacers). Built with the macOS 27 SDK when Xcode 27 is used, so the system chrome takes the 27 look |
| Swift tools | 6.2 (`Package.swift`) | `.macOS(.v26)` platform constant. Verified building with Swift 6.4.2 on Linux |
| Claude Code | 2.1.289 recommended | `plugin list --json` reports `readFromFolder` from this version [V]. Older versions still work, but a personal directory-marketplace plugin can only be proven Personal when its marketplace entry uses a relative path (rule P6), otherwise it shows as Read-only |

The real CLI used during M1 development in the cloud container was Claude Code 2.1.317; `plugin list --json` parsed without problems.
