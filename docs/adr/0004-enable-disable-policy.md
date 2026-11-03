# ADR-0004: How Clef enables, disables, installs and removes

- **Status:** Accepted for M2, revisit after spike S3
- **Source:** `TECHNICAL-DESIGN.md` section 9.8

| Operation | Mechanism |
| :- | :- |
| Plugin enable or disable | Direct edit of `enabledPlugins` in the chosen scope file (one atomic write per file), then verify with `claude plugin list --json` |
| Plugin install, uninstall, update; marketplace add and remove | `claude` CLI (they change Claude Code's own records and cache) |
| MCP add and remove | `claude mcp` CLI |
| MCP disable | `.mcp.json` servers: settings key; others: `disabledMcpServers` in `~/.claude.json` with compare-and-swap (S1, S7) |
| Skill, command, rule, subagent disable | Direct settings edit (`skillOverrides`, `claudeMdExcludes`, `permissions.deny`) |
| Skill, command, rule, subagent remove | Move to backup, never hard-delete |
| Hook disable and enable | Remove and stash, restore (no native switch) |

Every write goes through: plan, review diff, backup, atomic write, verify, history (`TECHNICAL-DESIGN.md` section 9).

## Consequences

The scanner already marks each item with its `control` mechanism and `capabilities`, so the M2 planner can map an action to exactly one row above.
