# ADR-0006: Xcode project for the app and its UI tests

- **Status:** Accepted (owner, 2026-11-05)
- **Closes:** the XCUITest part of M3.10

## Context

XCUITest needs an Xcode project with a UI test target. Claw was a Swift package only, and the app target was planned for M6. SwiftPM also leaves the String Catalog outside `Bundle.main`, so `swift run ClawApp` never reads it.

## Decision

Add `project.yml`, and generate `Claw.xcodeproj` from it with `xcodegen`. The project has the app, which links `ClawCore` from the package, and `ClawUITests`. The generated project is committed, so running the tests needs Xcode only; `xcodegen` is needed only to change the project.

`xcodegen` is a developer tool. It adds no code to the app and no dependency to `Package.swift`.

## Consequences

- `Package.swift` stays the source of truth for `ClawCore` and the CLI. `swift run ClawApp` keeps working.
- The app has two build definitions. Both take `Sources/ClawApp` as a folder, so new files need no project change.
- M6 starts from this target for signing and notarisation. Nothing here is signed for distribution.
- Commit `project.yml` and the regenerated project together.
