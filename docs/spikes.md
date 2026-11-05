# Spikes

Each spike turns an **[U]** in the docs into **[V]** or **[A]**. Plans are in `TECHNICAL-DESIGN.md` section 15. Run every spike in a **temporary config directory** (`CLAUDE_CONFIG_DIR=$(mktemp -d)`), never your real one, and paste only redacted output.

| Spike | Question | Status | Result |
| :- | :- | :- | :- |
| S1 | Structure of `~/.claude.json` (MCP servers, `projects`, `disabledMcpServers`) | Verified | See [S1](#s1-claudejson-structure) |
| S2 | `skillOverrides` for commands; merge across scopes; `Skill(plugin:name)` deny | Verified | Works for commands; merged per name; plugin skills ignore it. See [S2 and S6](#s2-and-s6-overrides-and-deny-rules) |
| S3 | Directory marketplace: what `marketplace add`, `install`, `plugin list --json` write; exact `known_marketplaces.json` shape | Verified | ADR-0004 row holds. See [S3](#s3-directory-marketplace) |
| S4 | Which changes apply live | Verified | See [S4 and S9](#s4-and-s9-live-changes-and-hooks) |
| S5 | Claude Desktop chat app config path and format | Partial | File found; this Mac has no MCP servers in it, so the format is not seen. See [S5 and S10](#s5-and-s10-what-this-mac-can-show) |
| S6 | Deny syntax for plugin subagents | Verified | `Agent(plugin:agent)`. See [S2 and S6](#s2-and-s6-overrides-and-deny-rules) |
| S7 | `deniedMcpServers`; value shape of `disabledMcpjsonServers` | Verified | See [S7](#s7-mcp-keys-in-settings) |
| S8 | `CLAUDE_CONFIG_DIR` effect on `~/.claude.json` | Verified | It moves the file. See [S8](#s8-claude_config_dir) |
| S9 | Hook removal live; matcher required | Verified | Live; matcher optional. See [S4 and S9](#s4-and-s9-live-changes-and-hooks) |
| S10 | macOS: TCC prompts, minimum macOS, managed profile, enterprise skills path | Partial | Paths read from the CLI; no profile and no fresh account here. See [S5 and S10](#s5-and-s10-what-this-mac-can-show) |

## Findings during M1 (cloud, Swift 6.4.2 on Linux)

| # | Finding | Evidence | Action |
| :- | :- | :- | :- |
| F1 | `JSONDecoder` on Linux accepted `{"a":1,}` | Failing test `Strict JSON` | Added `StrictJSON.validate` before decoding |
| F2 | `Process.terminate()` from the runner did not stop the child: SIGTERM stayed blocked in the child | Probe: a shell `trap … TERM` never fired; direct `Process` from the main thread worked | Spawn on a dedicated thread with an empty signal mask; SIGKILL after 2 s |
| F3 | `waitUntilExit` on Linux returns only when the child's pipes close; a grandchild keeps them open | Probe: `sh -c "sleep 6 & exit 0"` returned after 7 s | Timeout races exit against deadline + 3 s |
| F4 | Blocking `DispatchQueue.global()` threads starved Swift concurrency on a 2-core machine | Timeout fired only after the child exited | Blocking work runs on dedicated threads |
| F5 | Real `claude plugin list --json` (2.1.317) parsed with no problems; synced plugins appear with `@synced` ids | `claw scan --json` smoke test: 18 plugins (P2), 443 plugin skills, 5 personal skills | Fields match `plugins/cli-reference` |
| F6 | Full scan of all seven concepts on a real config (Claude Code 2.1.317, about 700 items) took 1.1 s; no secret values in the JSON output | `time claw scan --json`; grep for secret patterns | Meets `NFR-PERF-1` (warm scan under 3 s) in the container; measure again on the Mac |
| F7 | Exact JSON paths in `~/.claude.json` (`mcpServers`, `projects[<path>].mcpServers`, `disabledMcpServers`) are assumed | `MCPReader.readClaudeJson` | Confirm in S1; controls are marked `unknown` until then |

Re-check F2 and F3 on macOS: Foundation there is a different implementation.

## Findings during the first Mac session (macOS 27.2, Swift 6.4.2)

| # | Finding | Evidence | Action |
| :- | :- | :- | :- |
| F8 | A vertical `fixedSize` on text in a page without a `ScrollView` sets the window's minimum size to one character per line: the window grew to the screen and the sidebar went blank | Scan page at 1510 × 858; after the fix the window shrinks to 1100 × 732 on the same page | `PageHeader` subtitle uses `lineLimit(3)` |
| F9 | A scan reading `~/Documents` blocks inside `open()` until the macOS privacy dialog is answered; the app showed no reason. It waited 3228 s in one run | `sample` of the running app: `LocalFileSystem.readFile`, then `open`, on a cooperative thread; a `UserNotificationCenter` window was on screen | Fixed: see below |
| F10 | Real config holds a symlinked skill folder, `~/.claude/skills/manage-skills` into `~/.skills-manager`, and a disabled synced plugin with an empty `installPath` | The first version of `ContainedFileSystem` lost that skill, and reported reads of `/skills` and `/.mcp.json` at the disk root | The exception covers folders; a plugin with no path is listed but not read |

F9 result: Stop did not return during a blocked read, because `scan()` read on a cooperative thread and checked for cancellation only between steps (`BlockedReadTests`, failing before the fix). Nothing can interrupt `open()`, so Stop now walks away from it: each step reads on a dedicated thread through `StoppableFileSystem`, which returns on cancellation and then refuses further disk calls, so the abandoned thread cannot raise another dialog. That thread ends when `open()` returns. Measured through `AppModel` with an injected 900 s delay in `readFile`: Stop returned in 0.016 s and 0.024 s with a partial result. One disk call running for 3 s sets `ScanProgress.waitingOn`, and `ScanView` then shows the path and says macOS may be waiting for a prompt.

F9 limits: this ran against a test double and an injected delay, not a real privacy dialog (S10). A FIFO does not reproduce it on macOS: `Data(contentsOf:)` refuses one at once with `EACCES`. A bundled app also needs `NSDocumentsFolderUsageDescription` (M6).

## Spike results (Claude Code 2.1.316, macOS 27.2, 2026-11-05)

### How these ran

Every run set **both** `HOME` and `CLAUDE_CONFIG_DIR` to throwaway folders, because S8 was still open and the variable alone might have reached the real `~/.claude.json`. Sessions used a made-up API key and a stand-in for the Messages API on `127.0.0.1`, so no real credential was used and nothing reached Anthropic. The stand-in logs each request and can return a tool call, which shows what a session offers the model and what a tool call returns. The real `~/.claude.json` was only read, for key names and types, with values dropped.

Limits: "visible" means the name appears in the request sent to the model. Some rows come from reading strings in the CLI binary and are marked [binary]; those describe this version only. `$CFG` below is the config folder.

### S8: `CLAUDE_CONFIG_DIR`

| Environment | `.claude.json` | Backups |
| :- | :- | :- |
| Variable unset | `$HOME/.claude.json` | `$HOME/.claude/backups/` |
| Variable set | `$CLAUDE_CONFIG_DIR/.claude.json` | `$CLAUDE_CONFIG_DIR/backups/` |
| Variable set to `$HOME/.claude` | `$HOME/.claude/.claude.json`, **not** `$HOME/.claude.json` | `$HOME/.claude/backups/` |

Test isolation recipe: fake `HOME` too. The CLI also writes outside the config folder: `$HOME/Applications/Claude Code URL Handler.app` and `$HOME/Library/Caches/claude-cli-nodejs/`.

Claw bug: `ClaudeEnvironment.claudeJsonFile` compares the folder with `$HOME/.claude`, so the third row reads the wrong file. It has to ask whether the variable is set. Not fixed yet (see "Changes these results call for").

### S1: `.claude.json` structure

| JSON path | Holds | Evidence |
| :- | :- | :- |
| `mcpServers.<name>` | User-scope server: `type`, `command`, `args`, `env` | `claude mcp add --scope user` |
| `projects["<real path>"].mcpServers.<name>` | Local-scope server | `claude mcp add --scope local` |
| `projects["<real path>"].disabledMcpServers` | Array of names, off for that project only. Absent until first used | `/mcp disable` |
| `projects["<real path>"].enabledMcpjsonServers`, `.disabledMcpjsonServers` | Arrays, created empty; still honoured when filled by hand (S7) | Sandbox and real key names |
| `enabledMcpServers` | Opt-in list for one built-in default-off server only; not for ordinary servers | [binary] |

- `/mcp disable` puts a user, local or `.mcp.json` server in the same `disabledMcpServers` list, and `/mcp enable` removes it. A user server disabled in one project stayed on in another. `claude mcp list` then says "Disabled for this project".
- Project scope writes `.mcp.json` in the project, and nothing in `.claude.json`.
- `claude mcp remove` leaves the empty `mcpServers` object behind.
- Project keys are the resolved path (`/private/tmp/…`, not `/tmp/…`).
- On the owner's Mac: 7 projects, no top-level `mcpServers`, one project with `mcpServers`, and no `disabledMcpServers` key anywhere.

The first-run approval dialog for a `.mcp.json` server writes to `.claude/settings.local.json`, not `.claude.json`: "Use this and all future" gives `enabledMcpjsonServers` plus `enableAllProjectMcpServers: true`; "Continue without" gives `disabledMcpjsonServers`.

### S7: MCP keys in settings

`claude mcp list` after each change, with two `.mcp.json` servers `spike-a` (`/usr/bin/true`) and `spike-b` (`/usr/bin/false`):

| Setting | Result |
| :- | :- |
| `deniedMcpServers: [{"serverName": "spike-a"}]` in user settings | `spike-a` gone from the list |
| The same in project `.claude/settings.json` | `spike-a` gone: not limited to managed settings |
| `deniedMcpServers: [{"serverCommand": ["/usr/bin/false"]}]` | `spike-b` gone |
| `deniedMcpServers: ["spike-a"]` (bare string) | Ignored, with no message |
| `disabledMcpjsonServers: ["spike-a"]` in `settings.local.json`, project `settings.json`, user settings, or the project entry of `.claude.json` | `spike-a` gone in all four |
| `enabledMcpjsonServers: ["spike-a"]` in the project entry of `.claude.json` | Approved: "Pending approval" goes away |
| The same name in both `enabledMcpjsonServers` and `disabledMcpjsonServers` | Disabled wins |

Value shape: `disabledMcpjsonServers` is an array of server names; `deniedMcpServers` is an array of objects with `serverName`, `serverCommand` or a URL form [binary for the URL form]. A server off through these keys disappears from `claude mcp list`; one off through `disabledMcpServers` stays listed as disabled. OQ-2: the per-project answer stands, and `deniedMcpServers` is a working way to turn a server off everywhere.

### S3: Directory marketplace

`known_marketplaces.json` after `claude plugin marketplace add <folder>`:

```json
{ "spike-mkt": {
    "source": { "source": "directory", "path": "<folder>" },
    "installLocation": "<folder>",
    "lastUpdated": "2026-11-05T08:04:20.359Z" } }
```

| Step | Writes |
| :- | :- |
| `marketplace add` | `known_marketplaces.json`, and `extraKnownMarketplaces` in user settings |
| `plugin install --scope user` | Copy under `plugins/cache/<marketplace>/<plugin>/<version>/`; `installed_plugins.json` (`version: 2`, `plugins.<id>[]` with `scope`, `installPath`, `version`, `installedAt`, `lastUpdated`); `enabledPlugins[id] = true` in user settings |
| `plugin install --scope project` | `enabledPlugins[id] = true` in the project's `.claude/settings.json` |
| `plugin disable` and `enable` | `enabledPlugins[id]` set to `false` or `true`, kept as a key. The CLI rewrites the file and reordered its keys |

- `plugin list --json` adds `readFromFolder` and `folderVersion` for a directory marketplace, and `projectPath` for a project install. `marketplace list --json` gives `source: "directory"` and `path`.
- A later edit in the source folder did not reach the cached copy.
- Setting `enabledPlugins[id]` to `false` by hand shows as `enabled: false` in `plugin list --json`. ADR-0004 can keep its direct edit, and a minimal edit is kinder to the file than the CLI's rewrite.
- P6 evidence: `claw scan` on this sandbox put the plugin in Yours, and its skill and subagent in Read-only with `parentPlugin` control.
- `projectEnabled` (S4 question): `true` when the plugin is on through the current project's settings. From another folder the same project install gave `enabled: false`, `projectEnabled: false`. Run from inside the project it gave `true`, `true`; a user install gave `enabled: true`, `projectEnabled: false`.

### S2 and S6: overrides and deny rules

| Test | Result |
| :- | :- |
| `skillOverrides: {name: "off"}` for a user skill, project skill, user command, project command | Hidden from the model for all four; the Skill tool refused the two tried (project skill, project command) |
| Different names in user and local settings | Both apply: merged per name |
| Same name: user `off`, local `on` | On: the higher scope wins for that name |
| Same name: user `on`, local `off` | Off |
| Value `user-invocable-only` | Hidden from the model |
| Value `name-only` | Name still visible |
| `hello:greet` or `greet` as the key, for a plugin skill | No effect, and the Skill tool still launched it. A plugin skill is controlled through its plugin |
| `permissions.deny: ["Skill(name)"]`, for a skill, a command, and `Skill(hello:greet)` | Still listed, but the tool call returns "Skill execution blocked by permission rules" |
| `Agent(zzpagent)`, `Task(zzpagent)` | Hidden from the model. A call under the `Agent(…)` rule is refused, naming the rule; a call under `Task(…)` was not tried |
| `Agent(hello:helper)` (S6) | Same: the plugin subagent uses the `plugin:agent` name |
| `Agent(helper)` for that plugin subagent | No effect: the short name does not match |

Not tested: `skillOverrides` or a deny rule against a command the user types. The CLI has a message for the first case [binary].

### S4 and S9: live changes and hooks

One running session, config files changed on disk, then a new prompt.

| Change | Takes effect |
| :- | :- |
| `skillOverrides` set or removed | Live |
| `permissions.deny` for `Skill(…)`, `Agent(…)` | Live |
| Skill folder added or removed | Live |
| `enabledPlugins` | **Not live**: needs `/reload-plugins`, then the skill is gone or back |
| `disabledMcpjsonServers` in settings | **Not live**: the connected server kept working, even after `/reload-plugins` |
| `disabledMcpServers` edited in `.claude.json` | **Not live**: same as above |
| `/mcp disable <name>` typed in the session | Live: the tool is gone at once |
| Hook added in settings | Live, on the next prompt |
| Hook removed from settings | Live, on the next prompt |
| `claudeMdExcludes` | Applied after `/clear`, set and removed. Whether it applies without `/clear` is not known: this test could not tell |

New sessions pick up the MCP keys (`claude mcp list`, S1 and S7). So the after-apply text for an MCP disable made by Claw is "start a new session". A `ConfigChange` hook fired for each file change, with `source` of `local_settings`, `user_settings` or `skills`; it did not appear for the `.claude.json` edits.

Matcher (`PreToolUse`, tool call to Read):

| Group | Hook fired |
| :- | :- |
| No `matcher` key, `""` or `"*"` | Yes |
| `"Read"` | Yes |
| `"Bash"` | No |
| Empty `hooks` array, or an empty event array | No error |

So the matcher is optional, and removing the last handler can leave an empty group or event without harm. M2.7 can still remove them to restore the file exactly.

### S5 and S10: what this Mac can show

| Question | Result | Status |
| :- | :- | :- |
| Claude Desktop config | `~/Library/Application Support/Claude/claude_desktop_config.json` exists, top-level keys `preferences` and `coworkUserFilesPath`, no `mcpServers` | Format of a server entry not seen here, and not compared with the docs yet |
| Minimum macOS | `Package.swift` and `project.yml` say 26; built and run on 27.2 only. CI builds on a `macos-26` runner | No run on macOS 26 itself |
| Managed profile | The CLI reads `/Library/Managed Preferences/<user>/com.anthropic.claudecode.plist`, then `/Library/Managed Preferences/com.anthropic.claudecode.plist`, through `plutil` [binary]. Neither exists here, and `defaults read com.anthropic.claudecode` finds no domain | Needs a Mac with a profile |
| Managed folder | `/Library/Application Support/ClaudeCode`, with a `managed-settings.d` drop-in folder [binary]. Absent here | Needs a managed Mac |
| Enterprise skills path | Not found | Open |
| TCC prompts | F9 covers the blocked read; a fresh account was not tried | Needs a fresh user account, which only the owner can make |

### Changes these results call for

The owner approved these results on 2026-11-05.

| # | Change | Where |
| :- | :- | :- |
| 1 | S8 third row: decide by whether `CLAUDE_CONFIG_DIR` is set | `ClaudeEnvironment.claudeJsonFile` |
| 2 | A `.mcp.json` server turned off with `/mcp disable` lands in `disabledMcpServers`, which the project branch of the scan does not read, so Claw would show it on (from reading the code) | `ConfigScanner+Concepts.swift` |
| 3 | `disabledMcpjsonServers` and `enabledMcpjsonServers` in the project entry of `.claude.json` count too; the scan reads settings layers only (from reading the code) | Same |
| 4 | Item "Disable" for a plugin skill must never offer `skillOverrides` | Planner, M2.5 |
| 5 | Deny rules need the full `plugin:agent` name | Planner, M2.5 |
| 6 | Fill TD 3.4 and the after-apply text from S4 | M0.8, M4.7 |

## Findings during the spikes

| # | Finding | Evidence | Action |
| :- | :- | :- | :- |
| F11 | `resolvingSymlinksInPath` drops `/private` for a path that exists and keeps it for one that does not. Under a `/private/…` root, `ContainedFileSystem` reports every missing file as "Skipped a symlink that leaves the scan root" | 11 false warnings scanning the S3 sandbox; a small probe on `$SP/spk/s3/cfg` and `…/cfg/agents` shows the two forms | Only missing files, so no data is lost, but contract tests (M2.12) in `mktemp -d` will show it. Fix with item 1 |
