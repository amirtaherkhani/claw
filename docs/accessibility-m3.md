# M3.10 accessibility audit

`performAccessibilityAudit` on all 11 pages, with scanned sample data (`Tests/ClawUITests/SmokeTests.swift`), on macOS 27.2 on 2026-11-05. The first run reported 97 issues.

| Finding | Count | Outcome |
| :- | :- | :- |
| Search field without a description (History) | 1 | Fixed: labelled |
| Concept tiles with no group name (Overview) | 1 | Fixed: named "Configuration types" |
| Rail column with no group name | 11 | Fixed: named "Pages" |
| Window and split view groups with no description | 22 | Accepted: layout containers. VoiceOver reads the controls inside |
| System toolbar `Menu` reports a missing action | 11 | Accepted: a system control. It was also named "folder", the icon's name; it now has a label and the project as its value |
| Contrast failed or nearly passed | 51 | Excluded from the test, not closed; see below |

Any other finding fails the test.

## Contrast

Every text colour was computed against canvas, panel and rail backgrounds: the lowest is `Theme.muted` on the rail at 5.2:1, above the 4.5:1 of `NFR-A11Y-1`. The audit samples rendered pixels and flags small text, including system-drawn toolbar text. That points to false reports, but it was not proven. Check with Accessibility Inspector in M6.5.

## Not verified

- A VoiceOver walk-through by a person. The audit reads the accessibility tree; it does not listen.
- Part of the keyboard-only walk-through in the M3 exit criteria. Tested: ⌘R scans, ⌘1 to ⌘9 open pages, Esc closes a sheet. Not tested: opening an owner group, moving through the list and opening Detail, which need Tab to reach buttons. That depends on the macOS Keyboard navigation setting, which tests must not change. Hooks and History have no number shortcut; the Go menu reaches them.
- Reduce Transparency, Increase Contrast and larger text.
- Sheets: Add plugin opens in a test but is not audited, and neither are Review and Detail.
