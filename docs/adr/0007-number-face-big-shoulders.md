# ADR-0007: Big Shoulders for numbers

- **Status:** Accepted (owner, 2026-11-12)
- **Closes:** the number typography choice from the font review (three sample sheets of 15 Google Fonts)

## Context

Claw shows counts at four sizes: the Overview hero, the Overview cards, section and badge counts, and list counts and scan progress. They used the system font at sizes picked one by one. The owner wanted a tall, compressed display face for numbers, in the spirit of a condensed grotesk poster, with one consistent size scale.

CLAUDE.md asks for an ADR before adding anything third party. A font is not code, but it is a third-party file that ships in the app.

## Decision

Bundle **Big Shoulders** (variable, `opsz` 10–72 and `wght` 100–900) as `Sources/ClawApp/Resources/BigShoulders-Variable.ttf`, with its license next to it as `BigShoulders-OFL.txt`.

- **Source:** `google/fonts`, `ofl/bigshoulders/BigShoulders[opsz,wght].ttf`, at commit `c133902`.
- **License:** SIL Open Font License 1.1. It allows bundling in an app, as long as the license ships with the font and the font is not sold on its own.

`NumberFace` (in `Sources/ClawApp/NumberFace.swift`) loads the font straight from its file through CoreText; it never registers it system-wide. It sets the weight and the optical size for each step, and turns on tabular figures so changing counts do not shift sideways:

| Step | Points | Weight | Used for |
| :- | :- | :- | :- |
| XL | 96 | 200 | Overview hero count, in the accent colour |
| L | 56 | 800 | Overview card counts |
| M | 20 | 400 | Section counts |
| S | 13 | 600 | Scan progress, list counts |

Weight runs against size: the hero is thin because it is huge, and small counts are heavier so they stay legible. A **quiet** tone sets a number at 300 (never heavier than its step) when it says "nothing here", such as a zero; `numberFace(_:value:)` picks it for zero counts.

If the file is missing, `NumberFace` falls back to the system font with monospaced digits, at the nearest system weight.

The scope dial keeps its monospaced labels: they are names, not numbers.

## Consequences

- The app grows by about 320 KB.
- Both build definitions pick the font up without project changes: SwiftPM through `Bundle.module`, the Xcode target through `Bundle.main` (ADR-0006).
- Changing the number face later means replacing one file and this ADR, not every view.
- The font is used for digits and short count labels only. Running text stays in the system font.
