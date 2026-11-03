# ADR-0002: Name the app Clef

- **Status:** Accepted (2026-11-04)
- **Closes:** OQ-8

## Context

The owner asked for a short, creative name that is easy to remember and relates to Claude and configuration.

## Decision

**Clef.** It starts with "Cl" like Claude, and a clef is the sign at the start of a stave that sets how every note after it is read, the way this app sets how Claude is configured.

- Repository: `clef` · CLI: `clef` · Swift module: `ClefCore` · App: `ClefApp` (display name "Clef")
- Proposed bundle identifier: `com.amirtaherkhani.clef` [A, confirm before M6 signing]

## Consequences

- "Claude" is kept out of the product name. Using another company's trademark in an app name is a common reason for review problems; this is a precaution, not legal advice [A].
- Other projects named Clef exist (for example music software). Check App Store and GitHub name collisions before a public release [U].
