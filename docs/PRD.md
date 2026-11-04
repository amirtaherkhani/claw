# Product Requirements Document: Claw

> **Stack: Swift 6 + SwiftUI, app name Claw** ([ADR-0001](adr/0001-stack-swift-swiftui.md), [ADR-0002](adr/0002-name-claw.md)). Updated 2026-11-04. TypeScript blocks in `TECHNICAL-DESIGN.md` are kept as the behaviour spec; the Swift code in `Sources/ClawCore` implements them.


Version 0.1 · 2026-11-04 · Status: draft for implementation
Companion files: [`OVERVIEW.md`](OVERVIEW.md) · [`TECHNICAL-DESIGN.md`](TECHNICAL-DESIGN.md) · [`ROADMAP.md`](ROADMAP.md)
Tags: **[V]** verified in official docs · **[A]** assumption or recommendation · **[U]** unknown, closed by spike `S*` (see `OVERVIEW.md`).

---

## 1. Purpose

Claude Code and Claude Desktop load behaviour from many places: marketplace plugins, your own skills, slash commands, rules, subagents, MCP servers and hooks. They live in different files at different scopes, merge by precedence, and the built-in views show only part of the picture. Claw is a macOS app that answers four questions for every item:

1. **What is installed or active**, in this project and across this Mac?
2. **Where does it come from**, and can I change it? (Mine or someone else's.)
3. **Can I turn it off, on, or remove it**, safely and reversibly?
4. **Can I add a new one** without hand-editing JSON?

The prototype (Design canvas, Version 13) is the visual and behavioural reference: boards **Main** (Overview, Scan, Projects, Sources, List, Detail, History), **Review** and **Add plugin**.

## 2. Users and jobs

| | |
| :- | :- |
| **Primary user** | A solo power user with many projects (for example NestJS services and Siemens TIA Portal / SCL tooling), who installs marketplace plugins and also writes personal ones |
| **Secondary** | A teammate who clones a repo with a committed `.claude/` folder and wants to see what it turns on |

| Job | Example |
| :- | :- |
| J1 See what is active and its origin | "Which of these 14 skills come from a plugin and which are mine?" |
| J2 Switch something off without deleting it | Turn off a noisy SEO plugin for one project |
| J3 Remove safely, undo if wrong | Uninstall a plugin, then restore it |
| J4 Add my own | Register a local plugin folder, create a rule, add an MCP server |
| J5 Know what I may edit | Edit appears only on my own items |
| J6 Manage per project | Different hooks and rules in `my-nest-api` and `tia-scl-tools` |

## 3. Scope and priorities

| Priority | Meaning | Features |
| :- | :- | :- |
| **P0** | Needed for the first usable build (end of M4) | F01 to F08, F11 to F15, F17 |
| **P1** | Needed for 1.0 | F09 Add, F10 Edit source, F16 Preferences and diagnostics |
| **P2** | After 1.0 | F18 Claude Desktop chat-app MCP config; see also section 9 backlog |

**Non-goals (1.0):** editing item content inside the app (Edit opens your editor); a marketplace browser or store; syncing config between machines; Windows or Linux builds; managing `permissions`, `env`, `model` or other general settings; managing managed (IT-policy) settings (shown read-only); injecting commands into a running Claude session.

## 4. Concepts, ownership and capabilities

### 4.1 The seven concepts

| Concept | What it is | Main locations ([V] `claude-directory`, `skills`, `sub-agents`, `memory`, `mcp`, `hooks`) |
| :- | :- | :- |
| **Plugins** | Bundles of skills, commands, subagents, hooks, MCP servers | Records `~/.claude/plugins/installed_plugins.json`, `known_marketplaces.json`; files `~/.claude/plugins/cache/`; switches `enabledPlugins` in settings |
| **Skills** | Folders with `SKILL.md` Claude can load | `~/.claude/skills/<name>/`, `.claude/skills/<name>/`, nested `<subdir>/.claude/skills/`, plugin `skills/`, synced `~/.claude/skills/synced/` |
| **Commands** | Slash commands as `.md` files; merged into skills | `~/.claude/commands/*.md`, `.claude/commands/*.md`, plugin `commands/` |
| **Rules** | Standing instructions | `~/.claude/CLAUDE.md`, `./CLAUDE.md` or `./.claude/CLAUDE.md`, `CLAUDE.local.md`, `.claude/rules/**/*.md`, `~/.claude/rules/**/*.md` |
| **Subagents** | Specialised delegates as `.md` files | `~/.claude/agents/`, `.claude/agents/`, plugin `agents/` |
| **MCP servers** | External tool servers | `~/.claude.json` (local and user scope), `.mcp.json` (project scope), plugin `.mcp.json` |
| **Hooks** | Commands run on lifecycle events | `hooks` key in settings files, plugin `hooks/hooks.json`, skill and subagent frontmatter |

### 4.2 Scopes and precedence

[V] `settings`: Managed > `--settings` flag > Local (`.claude/settings.local.json`) > Project (`.claude/settings.json`) > User (`~/.claude/settings.json`). List-type keys such as `permissions.allow` merge across scopes. For `enabledPlugins` the value from the highest-precedence source that mentions the id wins ([V] `plugins/loading`). The `--settings` flag is session-only, so the app can never see or change it.

### 4.3 Ownership: who controls an item

| Ownership (badge) | Bucket | How it is recognised (summary; algorithm in `TECHNICAL-DESIGN.md` section 5) |
| :- | :- | :- |
| **Personal** | Yours | You wrote it: a file under your `~/.claude/` or a project's `.claude/`, or a plugin loaded **in place** from a **local directory marketplace** |
| **Project** | Yours | Same as Personal but stored in a project folder (badge shows scope) |
| **Marketplace** | Read-only | Plugin from a `github`, `git` or `url` marketplace, or from a local marketplace whose entry points to an external source (copied into the cache) |
| **Synced** | Read-only | Plugin id ends in `@synced`, or skill under `~/.claude/skills/synced/` (claude.ai account sync) |
| **From plugin** | Read-only | Component provided by an installed plugin |
| **Managed** *(new; missing in prototype)* | Read-only | Delivered by IT policy (for example `/Library/Application Support/ClaudeCode/`) |
| **Orphaned** | Needs attention | Install record or `enabledPlugins` entry whose marketplace or files are missing |

Rule: **when ownership cannot be proven, the item is Read-only.** The app never shows Edit unless ownership is proven.

### 4.4 Capability matrix

| Ownership | View | Edit | Disable / enable | Remove |
| :- | :- | :- | :- | :- |
| Personal / Project | Yes | Yes (opens your editor) | Yes | Yes (moved to backup; plugin: uninstall) |
| Marketplace | Yes | No | Yes | Uninstall |
| Synced | Yes | No | Plugin: yes [V]. Skill: all-or-nothing only (`syncClaudeAiSkills: false`) [V]. A plugin your organisation requires cannot be disabled [V] | Not from the app (manage on claude.ai) |
| From plugin | Yes | No | Via the parent plugin; per component only where a native switch exists (MCP yes [V]; skills: `skillOverrides` does **not** apply to plugin skills [V]; subagents: deny syntax [U] S6) | Via the parent plugin |
| Managed | Yes | No | No | No |
| Orphaned | Yes | No | n/a | Remove the record, or re-add the marketplace |

---

## 5. Feature specifications

Requirement IDs: `FR-F<nn>-<n>`. **MUST** = required for the feature's priority; **SHOULD** = expected unless justified; **MAY** = optional. Acceptance criteria use Given / When / Then.

### F01 Overview (P0)

- **Prototype:** Main › Overview. Particle ring, headline, stats, "Review N changes", "Scan all →".
- **Description:** First screen. Summarises the last scan and what is pending.

| ID | Requirement |
| :- | :- |
| FR-F01-1 | MUST compute all totals (items, enabled / total, per bucket, per concept) from the last scan result, never from static data |
| FR-F01-2 | MUST show when the last scan ran and its target (This Mac or a folder name) |
| FR-F01-3 | MUST show **Review N changes** only while the change queue is non-empty; N equals the queue length |
| FR-F01-4 | MUST show an empty state before the first scan with one primary action, **Scan all** |
| FR-F01-5 | MUST render the particle visual as a static image when the system setting Reduce Motion is on |
| FR-F01-6 | SHOULD link each concept tile to its Sources view (F04) |

**AC:** Given a scan with 7 plugins of which 6 are enabled, When Overview opens, Then it shows "6 / 7" for plugins and the same total in the status pill. Given 2 queued changes, Then the Review button reads "Review 2 changes".

### F02 Scan (P0)

- **Prototype:** Main › Scan. Target switch (This Mac / One project folder), progress, concept flow with "what it reads" labels, result groups Yours / Read-only / Needs attention, Stop keeps partial results.
- **Description:** Reads configuration for all seven concepts and sorts every item into a bucket. **Read-only by construction.**

| ID | Requirement |
| :- | :- |
| FR-F02-1 | MUST NOT write, move, delete or execute anything. The engine receives a read-only filesystem handle; a test asserts no write call is possible |
| FR-F02-2 | MUST support two targets. **This Mac:** user scope, managed scope (if present), plugin cache, registered projects, and projects listed in `~/.claude.json` [A] (key `projects` exists [V]; shape [U] S1). **One project folder:** that folder's project and local scope plus a bounded walk for nested `.claude/` folders |
| FR-F02-3 | MUST be cancellable. **Stop** returns within 500 ms [A] and keeps results found so far, labelled "partial" |
| FR-F02-4 | MUST show real progress from the engine (concepts finished, files read). The prototype's 4-second timer is a stub |
| FR-F02-5 | MUST NOT follow a symlink that leaves the scan root, and MUST NOT run hook commands, MCP servers or scripts found in a scanned folder |
| FR-F02-6 | MUST survive malformed files: attach a problem to the file or item and continue |
| FR-F02-7 | MUST NOT crawl the whole disk. "Find projects…" is a separate opt-in action over user-chosen folders (macOS privacy prompts [U] S10) |
| FR-F02-8 | MUST read only the paths in `TECHNICAL-DESIGN.md` section 3.1 (allowlist) |
| FR-F02-9 | SHOULD detect the `claude` CLI path and version and show missing-feature warnings |
| FR-F02-10 | SHOULD finish in under 3 s on a warm cache for 50 plugins, 200 skills and 20 projects [A] (`NFR-PERF-1`) |

**AC:** Given a fake HOME fixture with one item of each ownership, When a This Mac scan completes, Then every item appears in the expected bucket (golden file). Given a scan in progress, When Stop is pressed, Then the UI shows "Stopped, partial results" and the list contains only finished concepts. Given a scan target that contains a hook with `rm -rf`, Then nothing is executed.

### F03 Projects (P0)

- **Prototype:** Main › Projects, Add project folder modal (dashed drop zone, Browse), per-project actions.
- **Description:** A registry of project folders the app manages. Project-scoped items count only after their folder is in the registry.

| ID | Requirement |
| :- | :- |
| FR-F03-1 | MUST add a folder by drag and drop or **Browse**; the folder must exist and be a directory |
| FR-F03-2 | MUST de-duplicate by real path (symlinks resolved) |
| FR-F03-3 | MUST accept a folder with no `.claude/`, `.mcp.json` or `CLAUDE.md` and say "Nothing to manage yet" |
| FR-F03-4 | MUST offer per project: **Make active**, **Scan**, **Reveal in Finder**, **Remove from list**. Remove from list never touches files |
| FR-F03-5 | MUST persist the registry in the app's own state file and show per-project counts and last-scan time |
| FR-F03-6 | MUST mark a repository folder you did not author as "repository content": its config is shown but never executed |
| FR-F03-7 | SHOULD open the Browse dialog at a configurable default folder (suggested default `~/Documents/GitHub`) |

**AC:** Given `my-nest-api` is added, When it is made active, Then project-scoped items of `my-nest-api` appear and those of `tia-scl-tools` do not.

### F04 Sources (P0)

- **Prototype:** Main › per-concept flow ("Sources").
- **Description:** For one concept, shows where its items come from and how they split into Yours, Read-only and Needs attention.

| ID | Requirement |
| :- | :- |
| FR-F04-1 | MUST list the concept's real sources with counts (for skills: user, project, plugin, synced, managed) |
| FR-F04-2 | MUST open the filtered list (F05) when a bucket is clicked |
| FR-F04-3 | MUST show the **Scan all** and history shortcuts |
| FR-F04-4 | SHOULD show a source with zero items greyed, so users can see which locations were checked |

### F05 Item list and bulk actions (P0)

- **Prototype:** Main › list. Bucket sidebar with a "Backup first" card, kind chips, table, switch, select all, bulk bar.

| ID | Requirement |
| :- | :- |
| FR-F05-1 | MUST group and filter by bucket and by ownership kind; MUST show name, ownership badge, scope, one-line description, on/off switch |
| FR-F05-2 | MUST queue a change when a switch is toggled; MUST NOT write until Apply (F11) |
| FR-F05-3 | MUST offer bulk **Enable**, **Disable**, **Remove / Uninstall** for the selection; an action unavailable for any selected item is disabled with a reason tooltip |
| FR-F05-4 | MUST label the destructive action by concept: Uninstall (plugin), Move to backup (skill, command, rule, subagent), Remove server (MCP), Remove entry (hook) |
| FR-F05-5 | MUST work from the keyboard and expose row state to VoiceOver (`NFR-A11Y-1`) |
| FR-F05-6 | SHOULD offer text search and sort (not in prototype) |
| FR-F05-7 | MUST show items of an inactive project only when its folder is registered (F03) |

### F06 Item detail (P0)

- **Prototype:** Main › detail modal.

| ID | Requirement |
| :- | :- |
| FR-F06-1 | MUST show: name, ownership badge, scope, status, description, Details (paths, marketplace, provider, project folder), **Controlled by** (the exact key or file that decides the state), **On apply** (the exact diff), **How** text |
| FR-F06-2 | MUST show **Edit source…** only for ownership Personal or Project (`FR-F14-3`) |
| FR-F06-3 | MUST tag each "Controlled by" with its verification status **[V]**, **[A]**, **[U]** until spikes close |
| FR-F06-4 | MUST mask every secret value (env values, headers, tokens) and show only key names |
| FR-F06-5 | MUST offer **Copy path** and **Reveal in Finder** for file-backed items |
| FR-F06-6 | SHOULD show **Why is this Personal / Read-only?** with the rule and evidence (`FR-F14-2`) |

### F07 Enable and disable (P0)

- **Description:** Reversible switch. Meaning depends on the concept.

| Concept | Disable writes | Status |
| :- | :- | :- |
| Plugin | `enabledPlugins["name@origin"] = false` in the chosen scope file | [V] |
| Skill (own) | `skillOverrides["name"] = "off"` (other values `on`, `name-only`, `user-invocable-only`) | [V]; command-file coverage and merge semantics [U] S2 |
| Skill (from plugin) | Not possible with `skillOverrides` ("Plugin skills are not affected") | [V]; alternative deny rule `Skill(<namespaced name>)` [U] S2 |
| Command | Same switch as skills if it applies to command files | [U] S2 |
| Rule / CLAUDE.md | Add the absolute path (glob allowed) to `claudeMdExcludes` | [V] `memory`; managed CLAUDE.md cannot be excluded [V] |
| Subagent | `permissions.deny` entry `Agent(<name>)` | [V]; plugin subagents [U] S6 |
| MCP in `.mcp.json` | name in `disabledMcpjsonServers` (settings) | key [V], value shape [U] S7 |
| MCP (user, local, plugin, claude.ai connector) | name in `disabledMcpServers` in `~/.claude.json`, **stored per project** | [V] `mcp`; JSON path [U] S1 |
| Hook | Remove the entry and keep a stash copy (no per-hook switch exists) | [V] `hooks`; see F15 |

| ID | Requirement |
| :- | :- |
| FR-F07-1 | MUST write to the file of the currently selected scope (`SCOPEFILE`: User `~/.claude/settings.json`, Project `.claude/settings.json`, Local `.claude/settings.local.json`) |
| FR-F07-2 | MUST detect a higher-precedence source that overrides the change and warn before applying, using Claude Code's own wording as the model: "Disabled in user settings but still loads: project settings enable it" [V] |
| FR-F07-3 | MUST refuse and explain when the item is Managed, or a plugin your organisation requires [V] |
| FR-F07-4 | MUST NOT remove unknown keys or reorder the file (`NFR-SAFE-2`) |
| FR-F07-5 | MUST for MCP make the per-project nature explicit: "Disabled for project X" and let the user pick one project or all registered projects (OQ-2) |
| FR-F07-6 | SHOULD offer the global kill switch `disableAllHooks` as a separate, clearly labelled control with its effective value shown [V]: a `false` in a higher scope overrides a `true` in user settings |

**AC:** Given `searchfit-seo@searchfit` enabled in user settings, When disabled and applied at User scope, Then `~/.claude/settings.json` contains `"searchfit-seo@searchfit": false`, all other keys are byte-identical, and the next scan shows it disabled. Given the same plugin is `true` in `.claude/settings.local.json`, Then the app warns it will still load.

### F08 Remove and uninstall (P0)

| Concept | Mechanism | Status |
| :- | :- | :- |
| Plugin | `claude plugin uninstall <plugin> --scope <user\|project\|local> [--keep-data]` | [V] `plugins/cli-reference` |
| Skill, command, rule, subagent | Move the file or folder to `~/.claude.bak/<timestamp>/removed/` | [A] app policy: never hard-delete |
| MCP | `claude mcp remove <name> [--scope <scope>]`, or edit `.mcp.json` after backup | [V]; removing a remote server also deletes its stored OAuth tokens and client registration [V] |
| Hook | Remove the entry, keep the stash copy (F15) | [A] |

| ID | Requirement |
| :- | :- |
| FR-F08-1 | MUST ask for confirmation naming what will happen and what is kept |
| FR-F08-2 | MUST warn that uninstalling a plugin deletes its data directory unless **Keep data** is chosen [V: default deletes when removed from its last scope] |
| FR-F08-3 | MUST warn before removing a remote MCP server that stored sign-in will be deleted [V] |
| FR-F08-4 | MUST show an extra warning for a **guard hook** (event `PreToolUse` or `PermissionRequest`) because it may enforce safety or security rules [A] |
| FR-F08-5 | MUST make every remove undoable through F12 |
| FR-F08-6 | MUST NOT remove a Synced or Managed item; MUST point to claude.ai or the administrator |
| FR-F08-7 | MUST validate every name passed to the `claude` CLI against a strict pattern and call it without a shell (`NFR-SEC-2`) |

### F09 Add (P1)

- **Prototype:** Add plugin board (source chips, drop zone, items list, outcome panel, "Enable in" chips, CLI note).

**Add plugin**

| ID | Requirement |
| :- | :- |
| FR-F09-1 | MUST offer three sources: **Local folder**, **GitHub repo**, **Registered marketplace** |
| FR-F09-2 | MUST for a local folder run `claude plugin validate <path> [--json]` and show the result. Exit `0` = passed (with or without warnings), `1` = validation failed, `2` = the validator itself failed (nothing on stdout, message on stderr). `--json` needs Claude Code v2.1.259 or later [V] |
| FR-F09-3 | MUST show before adding what the result will be: **Personal** (editable, loaded in place) only for a local directory marketplace whose entry uses a relative path [V loading]; otherwise **Marketplace** (copied to cache, read-only) |
| FR-F09-4 | MUST add via `claude plugin marketplace add <source> [--scope user\|project\|local]` (default `user`) then `claude plugin install <name>@<marketplace> [--scope …]` (`-s` short form works for `install`, not for `marketplace add`) [V] |
| FR-F09-5 | MUST offer **Enable in** User / Project / Local and show the file the choice writes |
| FR-F09-6 | MUST verify afterwards with `claude plugin list --json` and report a mismatch (a bug report says directory-marketplace installs may not appear in `enabledPlugins` [U] S3) |
| FR-F09-7 | MUST show that `claude plugin marketplace add` with a GitHub shorthand rejects `owner/*` [V] |

**Add other concepts**

| Concept | Form | Writes |
| :- | :- | :- |
| Skill | name, description, optional frontmatter flags (`disable-model-invocation`, `user-invocable`, `allowed-tools`); starter template | `<scope>/skills/<name>/SKILL.md` |
| Command | name, description, body | `<scope>/commands/<name>.md` |
| Rule | file name, optional `paths:` globs, body | `<scope>/rules/<name>.md` |
| Subagent | `name` (no `:`, up to 256 chars), `description`, optional `tools`, `model` | `<scope>/agents/<name>.md` |
| MCP server | transport (stdio or http), command and args or URL, env and header **names** with secret values stored only where the user chooses, scope local / project / user | `claude mcp add …` or `.mcp.json` |
| Hook | event, matcher, handler type `command` with command and timeout | settings file of chosen scope |

| ID | Requirement |
| :- | :- |
| FR-F09-8 | MUST detect a name collision and explain precedence (enterprise > personal > project for skills; skill beats a same-name command) [V] |
| FR-F09-9 | MUST NOT write secret values into project files that are committed; prefer `${VAR}` references [V expansion in `.mcp.json`] and warn otherwise |
| FR-F09-10 | MUST write through the safe pipeline (F11); a new file counts as a change with an empty "before" |
| FR-F09-11 | SHOULD offer **New personal plugin** via `claude plugin init <name> [--description <text>] [--author <name>] [--author-email <email>] [--with skills agents hooks mcp lsp output-style channel] [-f]`. It scaffolds `~/.claude/skills/<name>/` and the plugin loads next session as `<name>@skills-dir`; there is no flag for another location [V] |

### F10 Edit source (P1)

| ID | Requirement |
| :- | :- |
| FR-F10-1 | MUST appear only on Yours items (`FR-F14-3`) |
| FR-F10-2 | MUST open the item's source in the user's chosen editor (default: system default for the file type; configurable in F16) |
| FR-F10-3 | For a Personal plugin MUST open the plugin's source directory inside the local marketplace folder (`readFromFolder` in `claude plugin list --json`, Claude Code v2.1.289 or later [V]) |
| FR-F10-4 | SHOULD refresh the item when the file changes on disk (file watch) |
| FR-F10-5 | MUST tell the user that edits to an in-place plugin apply at the next session start or `/reload-plugins`, with no version bump needed [V] |

### F11 Review changes and Apply (P0)

- **Prototype:** Review board. Two diff cards, three-line checklist, **Cancel** / **Apply N changes**.

| ID | Requirement |
| :- | :- |
| FR-F11-1 | MUST list every queued change with the target file and a real diff (red removed, green added) |
| FR-F11-2 | MUST state in the sheet that nothing is written until Apply, and show the backup folder it will create |
| FR-F11-3 | MUST re-check each target file's hash before writing; if it changed since the scan, MUST stop, rescan, and ask again |
| FR-F11-4 | MUST apply per the pipeline in `TECHNICAL-DESIGN.md` section 9: backup, atomic write, verify, history; on failure roll back what was written and report |
| FR-F11-5 | MUST mask secrets in the diff |
| FR-F11-6 | MUST show per-change result after Apply: applied, failed (with reason), rolled back |
| FR-F11-7 | MUST allow cancelling with Esc without side effects |
| FR-F11-8 | MUST show the hook-stash note for hook disable ("Claude Code has no per-hook disable, so the app removes the entry and restores it from its stash") |

**AC:** Given two queued changes, When Apply is pressed and the second write fails, Then the first file is restored from the backup, the sheet shows "1 applied then rolled back, 1 failed", and the settings files match their pre-Apply hashes.

### F12 Backups, History and Restore (P0)

- **Prototype:** Main › History (runs list with type icon, title, subtitle with time and file). Restore is a stub.

| ID | Requirement |
| :- | :- |
| FR-F12-1 | MUST create a timestamped backup folder before every Apply (default `~/.claude.bak/<ISO timestamp>/`, configurable) containing the original of each file to be changed, a `manifest.json`, and anything removed |
| FR-F12-2 | MUST list history entries with time, what changed, which files, and the backup location |
| FR-F12-3 | MUST restore a chosen entry through the same pipeline: show a diff (backup against current), create a new backup first, write, verify |
| FR-F12-4 | MUST create backup folders with mode 0700 and files 0600, because they may contain secrets (`NFR-SEC-4`) |
| FR-F12-5 | MUST NOT auto-delete backups. MAY offer manual pruning with a size readout (OQ-9) |
| FR-F12-6 | MUST NOT write into `~/.claude/backups/`, which Claude Code uses for `~/.claude.json` [V] |

### F13 Scope and active project (P0)

- **Prototype:** status pill: enabled / total bar, User / Project / Local switch, last backup, active-project button.

| ID | Requirement |
| :- | :- |
| FR-F13-1 | MUST show the scope switch; the chosen scope decides which file receives writes and which items are listed |
| FR-F13-2 | MUST require an active project for Project and Local scope and prompt to pick one |
| FR-F13-3 | MUST for MCP map the switch to local, project and user scope with their own files [V] and explain the difference from the settings scopes |
| FR-F13-4 | MUST show the target file path next to every write action |
| FR-F13-5 | SHOULD warn when writing to Project scope that the file is usually committed and shared |

### F14 Ownership classification (P0)

| ID | Requirement |
| :- | :- |
| FR-F14-1 | MUST classify deterministically by the algorithm in `TECHNICAL-DESIGN.md` section 5; same input, same output |
| FR-F14-2 | MUST be explainable: each item stores the rule that decided and its evidence (paths, marketplace source type) |
| FR-F14-3 | MUST default to Read-only when evidence is missing; Edit appears only for Personal and Project |
| FR-F14-4 | MUST re-classify on every scan; never cache ownership across scans |
| FR-F14-5 | MUST treat a plugin folder inside `skills/` that holds `.claude-plugin/plugin.json` as a skills-directory plugin (`name@skills-dir`, Personal), not as a plain skill [V loading] |

### F15 Hook stash (P0)

| ID | Requirement |
| :- | :- |
| FR-F15-1 | MUST on hook disable remove the entry from its settings file and store a copy (event, matcher group, handler JSON, source file, original position) in the app's state folder (mode 0600) |
| FR-F15-2 | MUST on enable re-insert the entry at its original event and matcher group; if the matcher group is gone, recreate it; if an identical handler already exists, do nothing and say so |
| FR-F15-3 | MUST include the stash entry in the backup of the same Apply |
| FR-F15-4 | MUST show stashed hooks in the list as Disabled (app-managed), including after an app restart |
| FR-F15-5 | MUST refuse to disable a Managed hook, a plugin's `hooks/hooks.json` hook, or a skill or subagent frontmatter hook (read-only) [V sources of hooks] |
| FR-F15-6 | SHOULD detect that Claude Code reloaded settings (files are watched [V]) and mark the change "live" after verification (S9) |

### F16 Preferences and diagnostics (P1)

| ID | Requirement |
| :- | :- |
| FR-F16-1 | MUST resolve the `claude` binary even when the app starts from Finder, where the shell `PATH` is not inherited [A]: try a user-set path, then a login-shell lookup, then common install locations |
| FR-F16-2 | MUST allow setting the backup folder, preferred editor, default project folder, scan defaults |
| FR-F16-3 | MUST show app version, `claude --version`, and the supported-version status (OQ-4) |
| FR-F16-4 | MUST provide **Copy diagnostics** containing versions, paths and counts and **no** secret or file content |
| FR-F16-5 | SHOULD let the user hide Managed items |

### F17 After-apply guidance (P0)

| ID | Requirement |
| :- | :- |
| FR-F17-1 | MUST after Apply show for each change when it takes effect: **live**, **after `/reload-plugins`**, or **after restart** |
| FR-F17-2 | MUST use [V] knowledge: plugin changes need `/reload-plugins` or a new session; skills and settings files are watched and apply live; changes to a plugin's hooks, `.mcp.json`, agents need `/reload-plugins` ([V] `skills`, `plugins/loading`, `settings`). Everything else is marked "verify" until S4 closes |
| FR-F17-3 | MUST offer **Copy `/reload-plugins`** and MUST NOT try to type into running sessions |

### F18 Claude Desktop chat-app MCP config (P2)

| ID | Requirement |
| :- | :- |
| FR-F18-1 | MAY list MCP servers from `~/Library/Application Support/Claude/claude_desktop_config.json` [A: path from third-party sources; official desktop page references the file name, path [U] S5] |
| FR-F18-2 | MUST NOT write until S5 verifies the format; disable would be remove-with-stash (no per-server switch known) |

---

## 6. Non-functional requirements

| ID | Requirement | Target |
| :- | :- | :- |
| NFR-SAFE-1 | A failed or interrupted Apply leaves each target file either fully old or fully new | Atomic rename; crash test passes |
| NFR-SAFE-2 | Unknown keys, key order, indentation and trailing newline of edited JSON are preserved | Byte-identical outside the edited path |
| NFR-SAFE-3 | No hard delete of user content; removal moves to backup | Test asserts no `unlink` of user files |
| NFR-SAFE-4 | Every write is preceded by a backup and followed by verification | Pipeline test |
| NFR-PERF-1 | Warm scan of a typical machine (50 plugins, 200 skills, 20 projects) | < 3 s [A] |
| NFR-PERF-2 | UI stays responsive during scan and apply (work off the UI thread) | No frame stall > 100 ms [A] |
| NFR-SEC-1 | Never execute content from scanned files (hooks, MCP, scripts) | Code review and test |
| NFR-SEC-2 | CLI calls without a shell, arguments validated | Test with hostile names |
| NFR-SEC-3 | No web content in the app: scanned text is shown as plain text, no `WKWebView`, child processes without a shell, hardened runtime | Checklist in `TECHNICAL-DESIGN.md` section 11 |
| NFR-SEC-4 | Backups and stash are private to the user (0700 / 0600) | Test |
| NFR-PRIV-1 | No network access except explicit user actions (marketplace add, update check if enabled); no telemetry | Network log test |
| NFR-PRIV-2 | Secrets masked in UI, diffs, logs and diagnostics | Redaction unit tests |
| NFR-A11Y-1 | Full keyboard operation, VoiceOver labels, contrast at least 4.5:1 for text, Reduce Motion respected | Accessibility audit before 1.0 |
| NFR-COMPAT-1 | Declare a minimum Claude Code version; degrade gracefully below it; show version gates | OQ-4 |
| NFR-COMPAT-2 | Parse config tolerantly: unknown fields ignored, malformed files reported, never crash | Fuzz tests |
| NFR-OBS-1 | Structured logs with correlation IDs, redacted, stored under `~/Library/Logs/<App>/` | Review |
| NFR-I18N-1 | All UI strings behind keys from day one; English first; layout checked for RTL (Persian) before 1.0 | [A] |
| NFR-DIST-1 | Signed with Developer ID, notarised, hardened runtime, distributed outside the Mac App Store [A] | OQ-6 |

## 7. Platform and compatibility

| Item | Value |
| :- | :- |
| OS | macOS 26 or later (Liquid Glass, SwiftUI APIs used); confirm in ADR-0005 and S10 |
| Claude Code | CLI present on `PATH` or user-set. Flags used are version-gated in the docs (for example `--json` on `plugin install / uninstall / update / enable / disable` v2.1.268 or later, `marketplace add --json` v2.1.287, `validate --json` v2.1.259, `readFromFolder` in `plugin list --json` v2.1.289). **Recommended baseline: v2.1.289 or later** [A] |
| Claude Desktop | Code tab reads the same settings files as the CLI [V `desktop`]; chat-app MCP config is P2 (F18) |
| Not supported | Windows, Linux, WSL |

## 8. Success criteria

| Criterion | Measure |
| :- | :- |
| Accuracy | On the author's Mac, the scan's plugin, skill, MCP, hook and subagent lists match `/plugin`, `/skills`, `/mcp`, `/hooks` and the subagent list for the same project |
| Safety | Zero unrecoverable changes during dogfooding; every Apply has a restorable backup |
| Speed | Disable a plugin in under 10 seconds from app launch |
| Trust | Edit never appears on a marketplace, synced, managed or from-plugin item (test across fixtures) |

## 9. Open questions and decisions

| ID | Question | Default if not decided | Decide by |
| :- | :- | :- | :- |
| OQ-1 | GUI technology | **Closed:** Swift + SwiftUI (ADR-0001) | Done |
| OQ-2 | MCP disable scope: one project, all registered projects, or global via `deniedMcpServers` [U S7] | One project, with "all registered" option | M0 spike S7 |
| OQ-3 | Which rule files count: the prototype lists `CLAUDE.md (user)` and `.claude/rules/*.md` | User and project `CLAUDE.md`, `CLAUDE.local.md`, rules; ancestors only inside the project root | M1 |
| OQ-4 | Minimum Claude Code version | v2.1.289 [A] | M0 |
| OQ-5 | Minimum macOS | macOS 26 proposed (ADR-0005) | M0 |
| OQ-6 | Mac App Store? The App Sandbox would block reading `~/.claude` without exceptions [A] | No: Developer ID only | M0 |
| OQ-7 | Auto-update mechanism | Decide in M6 | M6 |
| OQ-8 | Final app name and bundle id | **Closed:** Claw, `com.amirtaherkhani.claw` proposed (ADR-0002) | Done |
| OQ-9 | Backup retention | Keep all, manual prune with size readout | M2 |
| OQ-10 | In-app editor | No; open external editor | M5 |

Backlog after 1.0: F18, profiles and export / import bundles, plugin update and marketplace refresh controls, managed-policy viewer, live refresh on file change (FSEvents), menu-bar quick toggles, Windows and Linux ports.

## 10. Corrections to the prototype found while verifying

The prototype is a design reference; these points differ from verified behaviour and must change in the implementation.

| # | Prototype shows | Verified or better behaviour | Source |
| :- | :- | :- | :- |
| C1 | Toggle on **plugin-provided skills and commands** via `skillOverrides["ecc:tdd-workflow"]` | "Plugin skills are not affected" by `skillOverrides`. Show the parent plugin switch, or a deny rule once S2 verifies the syntax | `skills` |
| C2 | MCP disable looks global (`disabledMcpServers["github"]`) | The `/mcp` toggle is stored **per project** in `~/.claude.json` | `mcp` |
| C3 | Ownership list has no Managed | Add **Managed** (read-only), macOS path `/Library/Application Support/ClaudeCode/` | `managed-settings` |
| C4 | Synced appears for plugins only | Skills also sync into `~/.claude/skills/synced/` (download only, local edits overwritten) | `skills` |
| C5 | Personal plugin = "local directory marketplace" | Also requires the entry to use a relative path; an entry with an external source is copied into the cache | `plugins/loading` |
| C6 | No `@skills-dir` or `@inline` plugins | `@skills-dir` is Personal; `@inline` is session-only and invisible to a scan | `plugins/loading` |
| C7 | Hooks all appear togglable | Only settings-file hooks can be removed and stashed; plugin and frontmatter hooks are read-only | `hooks` |
| C8 | Add plugin: "check `claude plugin --help`" | Subcommands verified: `install`, `uninstall`, `enable`, `disable`, `update`, `list`, `details`, `configure`, `prune`, `validate`, `init`, `marketplace add / list / remove / update`; flags per section F09 | `plugins/cli-reference` |
| C9 | Restore and Edit are stubs | Both specified (F12, F10) | this document |
| C10 | Scan is a 4-second timer; Browse previews a sample folder | Real engine with progress events and a real folder picker | F02, F03 |
