# M1.15 comparison

`claw scan` compared with Claude Code on the owner's Mac, for the `claw` project, on 2026-11-05. Claude Code 2.1.316, macOS 27.2. Everything was read-only; no secret value appears here.

## How it was compared

| Source | Used for |
| :- | :- |
| `claude plugin list --json` | Plugin ids and enabled state |
| `claude plugin details <id>` for all 17 plugins | Skills, agents, hooks and MCP servers per plugin |
| Config files, by key name | User and project skills, commands, agents, hooks and MCP servers |
| `claw scan --json --project <claw>` | Claw's side |

## Result

| Concept | Claude Code | Claw | Verdict |
| :- | :- | :- | :- |
| Plugins | 17 | 17 | Same ids and enabled state |
| Plugin skills and commands | 144 | 144 (129 skills, 15 commands) | Same after the fixes below |
| Plugin MCP servers | 24 | 24 | Same after the fixes below |
| Plugin hooks | 1 | 2 | Explained |
| Plugin agents | 0 | 3 | Explained |
| User hook handlers | 17 in `settings.json` | 17 | Same |
| User skills, commands, agents | 1, 0, 0 on disk | 1, 0, 0 | Same |
| User and local MCP servers | 0, 0 in `~/.claude.json` | 0, 0 | Same |
| Project skill and rule | 1 skill, 1 `CLAUDE.md` | 1, 1 | Same |

Warm scan of this Mac: 0.8 s over three runs, 210 items, no problems (`NFR-PERF-1` allows 3 s). This Mac has fewer items than the target of 50 plugins and 200 skills.

## Differences

| Difference | Cause | Outcome |
| :- | :- | :- |
| `github@synced`: Claw found no MCP server | Its `.mcp.json` lists servers at the top level, with no `mcpServers` key | Fixed: a plugin's `.mcp.json` may use either shape |
| `desktop-commander@synced`: Claw found no MCP server | The server is declared inline in `.claude-plugin/plugin.json` | Fixed: inline `mcpServers` is read |
| `google-fonts`: Claw found no skill | `SKILL.md` is at the plugin root, with no `skills/` folder | Fixed: read when `skills/` holds no skill |
| Four plugins: more skills in `details` than in Claw | `details` counts commands as skills: signalwire 1 + 3, coding-skills 30 + 1, slack 9 + 5, searchfit-seo 11 + 6 | Explained |
| `signalwire`: 1 hook in `details`, 2 in Claw | One `SessionStart` group holds two handlers. Claw lists handlers | Explained |
| `searchfit-seo`: 0 agents in `details`, 3 in Claw | They are at `agents/<name>/AGENT.md`. A running Claude Code session listed all three under the same names as Claw, so `details` undercounts | Explained |

## Not verified

- The interactive views (`/plugin`, `/skills`, `/mcp`, `/hooks`, `/agents`) were not opened. `plugin details` and the config files stood in for them.
- `claude mcp list` was not run: it health-checks approved servers, which can start them.
- `claude plugin list --json` also returns `projectEnabled`, which Claw ignores. It was `false` for `google-fonts` while `enabled` was `true`, in a project that does not mention that plugin. Its meaning is unknown [U]; see S4 in `docs/spikes.md`.
- A plugin with both a root `SKILL.md` and a `skills/` folder [U]: Claw reads only the folder.
- This Mac has no user commands, agents or MCP servers, no managed layer and no synced skills, so those paths were compared at zero. `Tests/Goldens` covers them with fixtures.
- One project only. Repeat at M7 (`docs/ROADMAP.md` section 4).
