# ADR-0004: How Claw enables, disables, installs and removes

- **Status:** Accepted. Revised on 2026-11-11 at the owner's request: when Claude Code has a `claude` command for a change, Claw runs it; Claw makes a change itself only where no command exists, or when `claude` is not found. S3 confirmed the direct `enabledPlugins` edit on Claude Code 2.1.316; the contract tests confirmed `claude plugin enable/disable` and `claude mcp remove --scope project` on 2.1.319.
- **Source:** `TECHNICAL-DESIGN.md` section 9.8

## Rule

One table in code, `CommandCatalog.standard` (`Sources/ClawCore/Plan/ClaudeCommands.swift`), lists every action Claude Code's `claude` command makes, as an argument template (`{id}`, `{name}`, `{scope}`, `{keep-data}`) with the scopes it accepts. Every action not in that table is made by Claw itself. When Claude Code adds a command, adding its row moves that action to the CLI; nothing else changes.

For an action run by `claude`, the planner still works out what the command should write. The review shows that diff marked "written by claude", the backup keeps the file first, and after the run Claw checks that the file holds the planned values (`PlannedChange.expected`) and that `claude plugin list --json` agrees. A file that Claw and `claude` both write in one Apply is checked on its values, since `claude` rewrites the whole file in its own layout. If any check fails, the Apply is rolled back.

| Operation | Mechanism |
| :- | :- |
| Plugin enable or disable | `claude plugin enable` / `disable <id> --scope <scope>`. Without `claude`: direct edit of `enabledPlugins`. A plugin that is not installed: direct edit |
| Plugin install, uninstall, update; marketplace add and remove | `claude` CLI (they change Claude Code's own records and cache) |
| MCP add and remove | `claude mcp` CLI, also for a project's `.mcp.json` (`--scope project`, run in the project). Without `claude`: a `.mcp.json` server is cut by Claw; user and local servers cannot be removed |
| MCP disable | No command (`/mcp disable` exists only inside a session). `.mcp.json` servers: settings key; others: `disabledMcpServers` in `~/.claude.json` (S1, S7) |
| Skill, command, rule, subagent disable | No command. Direct settings edit (`skillOverrides`, `claudeMdExcludes`, `permissions.deny`) |
| Skill, command, rule, subagent remove | No command. Move to backup, never hard-delete |
| Hook disable and enable | No command. Remove and stash, restore |

Every write goes through: plan, review diff, backup, atomic write, verify, history (`TECHNICAL-DESIGN.md` section 9).

## Consequences

- `claude plugin enable/disable` rewrites the settings file in its own key order. Restore treats a file holding the backed-up values in another layout as already restored.
- Restoring a backup puts back the files a `claude` step changed; it does not reinstall an uninstalled plugin.
- The item detail shows, for each change, the `claude` command or Claw's own edit, and why.
