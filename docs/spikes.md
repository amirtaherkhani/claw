# Spikes

Each spike turns an **[U]** in the docs into **[V]** or **[A]**. Plans are in `TECHNICAL-DESIGN.md` section 15. Run every spike in a **temporary config directory** (`CLAUDE_CONFIG_DIR=$(mktemp -d)`), never your real one, and paste only redacted output.

| Spike | Question | Status | Result |
| :- | :- | :- | :- |
| S1 | Structure of `~/.claude.json` (MCP servers, `projects`, `disabledMcpServers`) | Open | |
| S2 | `skillOverrides` for commands; merge across scopes; `Skill(plugin:name)` deny | Open | |
| S3 | Directory marketplace: what `marketplace add`, `install`, `plugin list --json` write; exact `known_marketplaces.json` shape | Open | `MarketplaceReader` accepts `source` as a string or as `{ "source": …, "path": … }` until this closes |
| S4 | Which changes apply live | Open | |
| S5 | Claude Desktop chat app config path and format | Open | |
| S6 | Deny syntax for plugin subagents | Open | |
| S7 | `deniedMcpServers`; value shape of `disabledMcpjsonServers` | Open | |
| S8 | `CLAUDE_CONFIG_DIR` effect on `~/.claude.json` | Open | `ClaudeEnvironment` already honours the variable for `~/.claude` |
| S9 | Hook removal live; matcher required | Open | |
| S10 | macOS: TCC prompts, minimum macOS, managed profile, enterprise skills path | Open | |

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
| F9 | A scan reading `~/Documents` blocks inside `open()` until the macOS privacy dialog is answered; the app showed no reason. It waited 3228 s in one run | `sample` of the running app: `LocalFileSystem.readFile`, then `open`, on a cooperative thread; a `UserNotificationCenter` window was on screen | Fixed: see below |

F9 result: Stop did not return during a blocked read, because `scan()` read on a cooperative thread and checked for cancellation only between steps (`BlockedReadTests`, failing before the fix). Nothing can interrupt `open()`, so Stop now walks away from it: each step reads on a dedicated thread through `StoppableFileSystem`, which returns on cancellation and then refuses further disk calls, so the abandoned thread cannot raise another dialog. That thread ends when `open()` returns. Measured through `AppModel` with an injected 900 s delay in `readFile`: Stop returned in 0.016 s and 0.024 s with a partial result. One disk call running for 3 s sets `ScanProgress.waitingOn`, and `ScanView` then shows the path and says macOS may be waiting for a prompt.

F9 limits: this ran against a test double and an injected delay, not a real privacy dialog (S10). A FIFO does not reproduce it on macOS: `Data(contentsOf:)` refuses one at once with `EACCES`. A bundled app also needs `NSDocumentsFolderUsageDescription` (M6).

Re-check F2 and F3 on macOS: Foundation there is a different implementation.
