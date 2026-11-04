# ADR-0002: Name the app Claw

- **Status:** Accepted (2026-11-04, chosen by the project owner; replaces the earlier working name "Clef")
- **Closes:** OQ-8

## Decision

**Claw.** Short, easy to remember, sounds like "Cla(ude)", and suggests grabbing and moving the pieces of your setup.

- Repository: `claw` · CLI: `claw` · Swift module: `ClawCore` · App target: `ClawApp` (display name "Claw")
- Proposed bundle identifier: `com.amirtaherkhani.claw` [A, confirm before M6 signing]
- Short description: "Native macOS app to see, enable, disable and clean up everything that extends Claude Code."

## Risks

- **Brand confusion and trademark.** In 2026 the open-source agent "Clawdbot" was renamed (via "Moltbot") to **OpenClaw** after Anthropic raised a trademark concern about the original name. A "Claw" app for Claude Code may be confused with OpenClaw, or draw a similar objection, if it is published. Before a public release, search the App Store, GitHub and trademark databases. Avoid adding "Claude" to the product name. This is a risk note, not legal advice [A].
- The command name `claw` may clash with other tools on `PATH`. Check with `which claw` on the Mac.

## Consequences

Renamed everywhere before the first push: package, targets, CLI, docs, and Claw's own data folder (`~/Library/Application Support/Claw`).
