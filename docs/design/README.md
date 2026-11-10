# Design

The visual design Claw's SwiftUI app follows. Source of truth for layout, copy and states; the Swift code is the source of truth for behaviour.

## Files

| File | What it is |
| :- | :- |
| `prototype/Main.dc.html` | Main window board, 1360 × 820: rail, status bar, Overview, Scan, Projects, Sources flow, List, Detail, History, Add project, toast |
| `prototype/Review.dc.html` | Review changes board, 700 × 720 |
| `prototype/AddPlugin.dc.html` | Add plugin board, 860 × 760 |
| `prototype/canvas.json` | Board layout and the design notes shown on the canvas |

The `.dc.html` files are templates for the Claude Design canvas (`<x-dc>`, `{{ bindings }}`, `<sc-if>`, `<sc-for>`); they do not render as plain web pages. The interactive version is the published Design artifact: https://claude.ai/artifact/4x211CbHcazWvYVRFsMr3M (private to the owner). The board copies here are byte-identical to its version 18 of 2026-11-05.

To read a board without the canvas, strip the inline styles: the structure, copy and bindings are what matter.

## Design rules (from the canvas notes)

- Flat near-black surfaces, hairline borders, outlined pills, left icon rail, particle visuals. No gradients.
- One accent colour, lime `#D4F53C` (`--acc`). Yellow marks **Yours** only (editable items).
- Owner groups: Yours (yellow), Read-only (blue), Needs attention (orange); always with a text label.
- Hooks have no native per-hook disable; the app removes the entry and keeps a copy to restore.
- The source decides the badge: only a local directory marketplace makes a plugin Yours and editable.
- In the native app, glass comes only from system chrome (sidebar, toolbar, sheets); content stays flat (see the `liquid-glass` skill and `CLAUDE.md`).
- Button hierarchy: lime for the primary action, neutral for secondary actions, red for destructive ones. The root `.tint` is lime, so views set `.tint(Theme.text)` for neutral groups and `.tint(Theme.danger)` for destructive buttons.
- Mixed type in the prototype: numbers use a tall condensed face (`--num`), the last word of a title uses an italic serif (`--ser`), and uppercase section labels are monospace. Bebas Neue has capitals only, so split a count from its words and style just the digits. Buttons, paths and code stay in their plain fonts.

## Tokens

| Token | Value | SwiftUI (`Sources/ClawApp/Theme.swift`) |
| :- | :- | :- |
| Canvas | `#0B0B0C` | `Theme.canvas` |
| Panel | `#121214` | `Theme.panel` |
| Border | `#232327` (also `#28282C`) | `Theme.border` |
| Text | `#F2F2F3` | `Theme.text` |
| Muted | `#8E8E93` | `Theme.muted` |
| Accent | `#D4F53C` | `Theme.accent` |
| Yours | `#FFD60A` | `Theme.yours` |
| Read-only | `#6EA3FF` | `Theme.readonly` |
| Needs attention | `#FF7A59` | `Theme.attention` |
| Destructive actions | `#FF8F85` | `Theme.danger` |
| Selected segment | `#2E2E33` | `Theme.segment` |
| Rail selected tile, label | `#1C1C1F`, `#9A9AA0` | `Theme.railSelected`, `Theme.railLabel` |
| Font | DM Sans in the prototype | System font (SF Pro) in the app [A]: native, Dynamic Type, no font licence to bundle |
| Number font (`--num`) | Bebas Neue, prototype only | Not in the app |
| Accent font (`--ser`) | Instrument Serif italic, prototype only | Not in the app |

## Board to code map

| Prototype part | SwiftUI file | State |
| :- | :- | :- |
| Rail | `RootView.swift` (`RailView`, `RailEntry`) | Done: 76 pt icon rail inside the split view's sidebar column; `RailEntry` also drives the Go menu (⌘1 to ⌘9) |
| Status bar: enabled count, scope switch, last backup, Review, active project | `RootView.swift` (`StatusToolbar`, subtitle) | Done; "last backup" waits for M2 |
| Overview: particle ring, headline, cards | `OverviewView.swift` | Done; "changes applied" and backup cards show placeholders until M2 |
| Scan: targets, concept flow, progress, Stop | `ScanView.swift`, `FlowView.swift` | Done |
| Projects: rows, drop zone | `ProjectsView.swift` | Done |
| Add project sheet | `ProjectsView.swift` (`AddProjectSheet`) | Done |
| Sources flow per concept | `ConceptView.swift`, `FlowView.swift` | Done |
| List: owner groups, chips, table, bulk actions, select all | `ConceptView.swift` (`ItemListView`) | Done |
| Detail | `Sheets.swift` (`ItemDetailSheet`) | Done; Edit opens the file in the default editor |
| History | `Sheets.swift` (`HistoryView`) | Shell only; records arrive with M2 |
| Review board | `Sheets.swift` (`ReviewSheet`, `ReviewEntryCard`, `ReviewChecklist`) | Real diffs from the Planner (M4.2); Apply connected in M4.3 |
| Add plugin board | `Sheets.swift` (`AddPluginSheet`) | Inspection done; install disabled until M5 |
| Toast | `Components.swift` (`ToastView`) | Done |

Every screen was compared with the boards on macOS 27.2 on 2026-11-04. Remaining differences: "last backup" in the status bar (M2) and the system font instead of DM Sans [A]. The mixed type added to the boards on 2026-11-05 is not in the app and was not part of that comparison.
