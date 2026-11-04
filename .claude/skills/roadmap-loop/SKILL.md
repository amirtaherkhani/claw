---
name: roadmap-loop
description: Run Claw's development loop for the next roadmap task: branch, test-first implementation, local checks, pull request, wait for CI, merge, sync main, then continue with the next task. Use when asked to continue the roadmap, do the next step, work through a milestone, or run the develop-test-PR-merge loop.
---

# Roadmap loop

One roadmap task per pass: **pick → branch → plan → test first → implement → check → PR → CI → merge → sync → sweep → log → next**. Repeat until a stop condition is hit or the requested amount of work is done.

Read `CLAUDE.md` before the first pass. Its rules win over this file.

## Inputs

- No argument: do passes until the end of the current milestone, then stop for review.
- A task id such as `M2.3`: do only that task.
- A number such as `3`: do at most that many tasks.

## 0. Preflight (every pass)

1. `git status --short` must be empty. If not, stop: those changes are not yours to discard.
2. `git checkout main && git pull --ff-only`. If the pull is not a fast-forward, stop and report.
3. `gh auth status` must succeed, and `gh repo view --json nameWithOwner` must show `amirtaherkhani/claw`.
4. `swift build && swift test` on main must pass. If main is red, fixing main is the task (a `fix/` branch); do not start new work on a red main.

## 1. Pick the task

1. Read the **Task log** in `docs/NEXT-STEPS.md` (what is done) and the current milestone's plan there.
2. Take the first task that is not in the log. Cross-check its row (id, acceptance criteria, files) in `docs/ROADMAP.md`.
3. If the task needs a decision listed under **Stop conditions**, stop before branching and ask.

## 2. Branch and plan

1. Branch from main: `feat/<id>-<short-slug>` (for example `feat/m2-1-json-edit`); `fix/…` for fixes, `docs/…` for docs-only work.
2. Write a short plan: acceptance criteria (from the roadmap row), files to touch, tests to add, risks. For a task larger than one file, show the plan before coding.

## 3. Implement test-first

1. Write the failing Swift Testing test first and run it to see it fail for the right reason.
2. Implement the smallest change that passes. Follow the existing structure, naming and patterns.
3. Keep `ClawCore` free of UI types and buildable on Linux.
4. Never weaken a check to get green: no deleted or loosened assertions, no skipped tests, no lint suppressions.

## 4. Local checks (all must pass)

```sh
swift build
swift format lint --strict --recursive Sources Tests Package.swift
swift test
```

When `Sources/ClawApp` changed, also run the `liquid-glass` skill linter on `Sources/ClawApp` (`--target 26.0`) and launch `swift run ClawApp` to look at the changed screen.

Report each check as passed, failed, skipped or not run.

## 5. Update docs in the same branch

- Add the task to the **Task log** in `docs/NEXT-STEPS.md`: id, one-line summary, PR number, date.
- Update the "Where it stands" table when a milestone changes state.
- New facts from spikes go to `docs/spikes.md`; replace [U] with [V] or [A] where they apply.
- Keep code, docs and examples consistent in one change.

## 6. Commit, push, open the PR

1. Small, focused commits in Conventional Commits style (`feat(core): …`, `fix(app): …`, `docs: …`), matching `git log`.
2. Never `--no-verify`, never force-push a shared branch, never commit to main.
3. `git push -u origin <branch>`
4. `gh pr create --base main --title "<id>: <summary>" --body-file <file>` with this body:

```markdown
## Task
<id> from docs/ROADMAP.md: <acceptance criteria>

## Changes
- <file>: <what and why>

## Checks
| Check | Result |
| :- | :- |
| swift build | passed |
| swift format lint --strict | passed |
| swift test | passed (<n> tests) |
| liquid-glass linter | passed / not applicable |

## Not verified
- <anything not run, and why>
```

## 7. Wait for CI and fix

1. `gh pr checks <number> --watch --fail-fast`
2. On a failure: read the log (`gh run view <run-id> --log-failed`), find the root cause, fix it in this branch, rerun the local checks, push.
3. If the same check fails twice for the same reason, or the failure is not caused by this PR (also red on main), stop and report.

## 8. Merge gate

Merge only when **all** of these are true:

- every check on the PR head is green (`gh pr checks <number>`)
- `gh pr view <number> --json mergeable,mergeStateStatus,reviewDecision` shows mergeable, no conflicts and no requested changes
- no unresolved review comment from a person
- the PR changes only what the task needs

Then: `gh pr merge <number> --squash --delete-branch`

Never merge a red or conflicting PR. Never approve your own PR.

## 9. Sync and continue

1. `git checkout main && git pull --ff-only`
2. Confirm CI on main for the merge commit (`gh run list --branch main --limit 1`).
3. Give a three-line pass report: task, PR link, checks.
4. Run the branch sweep (section 10).
5. Continue with step 0 for the next task, unless a stop condition applies.

## 10. Branch sweep

Run this every time work on a section of `docs/ROADMAP.md` (a task in M0 to M7) finishes, before the next task starts, so branches do not pile up.

1. **Merge what is ready.** `gh pr list --state open --json number,title,headRefName,mergeable,mergeStateStatus`. Oldest first, put each PR through the merge gate (section 8) and the stop conditions. If it passes: `gh pr merge <number> --squash --delete-branch`. Recheck the rest after each merge, because one merge can make the next PR conflict.
2. **Leave the rest in place.** A PR that fails the gate or hits a stop condition stays open, and the report says why. The sweep never overrides either one. A conflict that touches only docs tables may be resolved in that PR's branch; push, wait for CI, then apply the gate again.
3. **Branches with no PR are not merged.** The default branch changes only through pull requests. List them in the report; open a PR only if the work is finished and yours.
4. **Delete merged branches.** Squash merges hide from `git branch --merged`, so check each branch against its PR: `gh pr list --state merged --head <branch> --json number,headRefOid`. Delete only when `headRefOid` equals the branch tip, so commits added after the merge survive: `git branch -D <branch>`, and `git push origin --delete <branch>` if it is still on the remote.
5. **Keep what is in use.** Never delete `main`, a branch checked out in a worktree with a running session, or a worktree with uncommitted changes.
6. `git fetch --prune`, then report: merged, left open and why, branches deleted, branches kept and why.

## Stop conditions (stop and ask before going on)

- **Real configuration:** anything that would modify, or run `claude` against, the real `~/.claude`, `~/.claude.json` or a real project. Spikes and contract tests use `CLAUDE_CONFIG_DIR="$(mktemp -d)"` only, and their results need the owner's review before code depends on them.
- **Unverified controls:** enabling Apply, Restore or Install for a control whose status is `unknown`.
- **Decisions:** adding a dependency, changing a public type in `Sources/ClawCore/Model`, anything that needs an ADR, changing the minimum macOS or Swift version.
- **Visual review:** UI work whose result needs the owner's eyes (visual parity with `docs/design/`, new screens). Open the PR, do not merge; ask for a review.
- **Release work:** signing, notarisation, publishing, version tags (M6, M7).
- **CI:** the same failure twice, a failure that is not this PR's, or main red.
- **Review:** a person requested changes or left an open question.
- **Merge conflict** that touches logic on both sides.
- **End of milestone:** check the milestone's exit criteria in `docs/ROADMAP.md`, report them, and stop for the owner's review.
- **Secrets:** anything that would print, log or commit a secret value.

When stopping, say exactly what is blocked and what decision or action is needed. Leave the branch and PR in place.
