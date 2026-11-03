# Config Manager: implementation docs

> **Update 2026-11-04 — stack and name changed.** The app is now **Clef**, built in **Swift + SwiftUI** ([ADR-0001](adr/0001-stack-swift-swiftui.md), [ADR-0002](adr/0002-name-clef.md)). Where this document says TypeScript, Electron, React, pnpm, zod or `jsonc-parser`, read the Swift equivalent: the TypeScript blocks are the **behaviour spec**, ported to `Sources/ClefCore`. Requirements, ownership rules, spikes and the milestone order are unchanged.


Working name: **Config Manager** (rename freely; nothing below depends on it).
Docs date: 2026-11-04. Prototype: Design-canvas artifact, Version 13 (boards Main, Review, Add plugin).

A macOS app that lets you **see, add, disable, enable and remove** the seven kinds of Claude Code and Claude Desktop extensions from one place: plugins, skills, commands, rules, subagents, MCP servers and hooks. It shows an **Edit** button only on items you own.

## Answer first

- **Build it as a new app, do not fork Skill Forge.** The only GUI candidate with a matching stack (Tauri 2 + Svelte 5, MIT) was, when checked on 2026-11-04, a repository with 4 commits, 0 stars, no releases, and no documented per-item enable/disable or ownership detection outside MCP servers. See `TECHNICAL-DESIGN.md` section 2.
- **Recommended stack: a UI-independent TypeScript core library, a CLI on top of it, then an Electron + React shell.** The core and CLI deliver value (and tests) before any GUI exists. This is a recommendation, not a verified fact; the GUI shell can still switch to Tauri without touching the core.
- **Everything the app writes goes through one safe pipeline**: plan, review diff, backup, atomic write, verify, record history. Files are never hard-deleted.
- **Most config contracts are now verified** against the official Claude Code docs. A short list is still unknown and is closed by spikes in milestone M0 (below).

## Documents

| File | Read it for | Audience |
| :- | :- | :- |
| [`PRD.md`](PRD.md) | What the app does: users, scope, the 18 features (F01 to F18) with requirements (`FR-*`), acceptance criteria, non-functional requirements (`NFR-*`), open questions, corrections to the prototype | Product decisions, QA |
| [`TECHNICAL-DESIGN.md`](TECHNICAL-DESIGN.md) | How to build it: verified config-file contracts per concept, ownership algorithm, data model, scan engine, safe write pipeline, architecture, security, testing, packaging, spikes | Implementers |
| [`ROADMAP.md`](ROADMAP.md) | In what order: milestones M0 to M7 with tasks, exit criteria, risks, a day-one checklist and a `CLAUDE.md` template for the app repo | Whoever builds it |

Reading order: this file, `PRD.md` sections 4 and 5, `TECHNICAL-DESIGN.md` sections 3 to 9, then `ROADMAP.md` M0.

## Verification legend (used in all three files)

| Tag | Meaning |
| :- | :- |
| **[V]** | Verified in the official Claude Code documentation on 2026-11-04. The page and, where the docs state one, the Claude Code version are cited. |
| **[A]** | Assumption or recommendation. Reasonable, not confirmed by a source. |
| **[U]** | Unknown. A spike (`S1` to `S10`) says how to find out. |

The installed Claude Code version on your Mac was **not** inspected. Several CLI flags are gated by version in the docs (for example `claude plugin list --json` field `readFromFolder` needs v2.1.289 or later). Check with `claude --version` and `claude plugin <subcommand> --help` before relying on a flag.

## What is still unknown (closed in M0)

| Spike | Question | Why it matters |
| :- | :- | :- |
| S1 | Exact JSON structure of `~/.claude.json` (user and local MCP servers, `projects`, `disabledMcpServers`) | MCP read and write, project discovery |
| S2 | Does `skillOverrides` apply to command files? What is the merge behaviour across scopes? How do you deny a plugin skill by its namespaced name? | Skills and commands toggle |
| S3 | Does a directory-marketplace install write `enabledPlugins`? (A bug report suggested it may not.) | Personal plugin detection and toggle |
| S4 | Which changes apply live and which need `/reload-plugins` or a restart | Post-apply guidance (F17) |
| S5 | Claude Desktop chat app: config path and format (only third-party sources found; the official desktop page references `claude_desktop_config.json`) | F18 |
| S6 | Deny syntax for plugin-provided subagents | Subagent toggle |
| S7 | Semantics and value shape of `deniedMcpServers` and `disabledMcpjsonServers` | MCP toggle |
| S8 | Where `~/.claude.json` lives when `CLAUDE_CONFIG_DIR` is set | Test isolation |
| S9 | Does removing a hook entry take effect live (settings are watched)? | Hook disable |
| S10 | macOS specifics: privacy prompts (TCC) when scanning `~/Documents`; minimum macOS for the chosen Electron release; reading a managed configuration profile; macOS path of the enterprise skills directory | Scan UX, distribution, managed scope |

## Proposed repository layout (for the new repo)

Create it on your Mac as `/Users/mac/Documents/GitHub/<repo-name>`. That path does not exist in this cloud session, so nothing was created there.

```text
<repo-name>/
├─ CLAUDE.md                  # from ROADMAP.md appendix B
├─ docs/                      # these files + ADRs + spike reports
├─ packages/
│  ├─ core/                   # scan, classify, plan, apply, backup (no UI, no Electron)
│  ├─ cli/                    # `cfgmgr` command on top of core
│  ├─ contracts/              # shared zod schemas and TypeScript types (IPC, JSON files)
│  └─ fixtures/               # fake HOME trees for tests
├─ apps/
│  └─ desktop/                # Electron main, preload, React renderer
└─ pnpm-workspace.yaml        # [A] pnpm for a new repo; follow the lockfile if you choose otherwise
```

## Glossary

| Term | Meaning |
| :- | :- |
| **Concept** | One of the seven kinds: plugins, skills, commands, rules, subagents, MCP servers, hooks |
| **Scope** | Where a setting or file lives: Managed, User, Project (shared), Local (project, gitignored). Plugin and Synced items carry their own origin |
| **Ownership** | Who controls an item: Personal, Project, Marketplace, Synced, From plugin, Managed, Orphaned. Decides which actions are allowed |
| **Bucket** | The three groups in the UI: **Yours** (editable), **Read-only**, **Needs attention** |
| **Change plan** | The list of operations the user queued; shown in the Review sheet before anything is written |
| **Apply** | Backup, write, verify, record history |
| **Stash** | The app's own copy of a removed hook entry so it can be restored |
| **Spike** | A short experiment on a real Mac that turns an **[U]** into **[V]** or **[A]** |

## Sources

Official Claude Code documentation, fetched 2026-11-04: [settings](https://code.claude.com/docs/en/settings), [settings reference](https://code.claude.com/docs/en/settings-reference), [`.claude` directory](https://code.claude.com/docs/en/claude-directory), [plugin loading](https://code.claude.com/docs/en/plugins/loading), [plugin CLI reference](https://code.claude.com/docs/en/plugins/cli-reference), [plugin manifest](https://code.claude.com/docs/en/plugins/manifest-reference), [marketplace reference](https://code.claude.com/docs/en/plugins/marketplace-reference), [skills](https://code.claude.com/docs/en/skills), [subagents](https://code.claude.com/docs/en/sub-agents), [memory and rules](https://code.claude.com/docs/en/memory), [hooks](https://code.claude.com/docs/en/hooks), [MCP](https://code.claude.com/docs/en/mcp), [managed settings](https://code.claude.com/docs/en/managed-settings), [desktop](https://code.claude.com/docs/en/desktop).
Candidate fork reviewed: [HayriCan/SkillForge](https://github.com/HayriCan/SkillForge) (README only; source code not reviewed).
