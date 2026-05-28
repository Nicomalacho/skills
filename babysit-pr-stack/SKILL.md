---
name: babysit-pr-stack
description: Babysit a stack of dependent GitHub pull requests end-to-end — discover every PR in the stack from a starting branch or PR, poll each one's CI / review / mergeability, and cascade-rebase children automatically when an ancestor lands or moves. Resolves simple rebase conflicts in place (lockfiles, import collisions, non-overlapping adjacent edits, whitespace) and surfaces complex ones with diagnosis. Use this whenever the user asks to watch, monitor, babysit, manage, land, or unblock a stacked PR set, a chain of PRs, dependent branches, a "stack of changes", or says things like "PR X is on top of PR Y" or "rebase the stack when the bottom merges" — even if they don't say the word "stack" explicitly. Prefer this skill whenever more than one open PR is chained head→base.
---

# Stacked PR Babysitter

## Objective

Drive a stack of dependent GitHub PRs to a clean landing — bottom merges, children rebase onto the new base automatically, conflicts are auto-resolved when safe and escalated when not, and per-PR CI / review state stays monitored across every PR.

## When to use

- The user mentions a stack, chain, train, or series of PRs.
- The current branch or anchor PR has another open PR's head as its base (its `base` is not the repo's default branch).
- The user asks to "rebase the stack when X merges" or "keep the stack green".
- More than one open PR exists where one's `base` equals another's `head`.

For an isolated single PR (base = default branch, no children) the cross-PR coordination here is overkill — handle it as a normal PR.

## Inputs

Accept any of:

- **No argument** — discover the stack from the current branch. Resolve the PR with `gh pr view --json number,baseRefName,headRefName,state`, then walk.
- **A single anchor PR** (number or URL) — walk up and down from there.
- **An explicit ordered list** of PR numbers (bottom→top). Trust the order.

## Stack discovery

Build the ordered list bottom→top before acting. Order matters — rebases must cascade in that direction.

1. Resolve the anchor PR.
2. **Walk down** toward the default branch: for each PR, look up the open PR whose `headRefName` equals this one's `baseRefName`. Stop when `baseRefName` is the default branch, or there is no matching open PR (flag this as a "loose base" to the user; don't silently assume it's the bottom).
3. **Walk up** away from the default branch: look up open PRs whose `baseRefName` equals each PR's `headRefName`. When multiple children share one parent, distinguish **fan-out** (siblings meant to land in parallel — typical signs: matching ticket prefix, no grandchildren — manage in parallel) from a **true fork** (competing alternatives — surface and let the user pick). When ambiguous, ask.
4. Print the discovered stack to the user before acting. A wrong order will corrupt history.

Full `gh` commands, the walking pseudocode, and edge cases (closed-PR gaps, cross-fork PRs, renamed defaults): see `references/stack-discovery.md`.

## Per-tick workflow

Each tick:

1. **Refresh the stack** — PRs may have merged or closed. Re-run discovery if any anchor disappeared.
2. **Snapshot every PR** bottom→top. Capture state, head SHA, base branch, `mergeStateStatus`, failing checks, new review items. Persist between ticks; see `references/snapshot-format.md` for the schema and file location.
3. **Detect cascade triggers** by combining the snapshot diff with each PR's `mergeStateStatus`:
   - **Snapshot diff:** a previously-open PR is now `MERGED` → its children need rebasing onto the new base. A previously-open PR has a new head SHA → every PR above it needs rebasing.
   - **`mergeStateStatus`:** routes to a specific action per value (`DIRTY` → rebase, `BEHIND` → rebase, `UNSTABLE` → inspect checks, `BLOCKED` / `UNKNOWN` → wait, `CLEAN` → no cascade work). See `references/merge-state-table.md` for the full table — these values are not interchangeable.
4. **Act on the lowest unresolved trigger first.** Cascades propagate upward, so handling the bottom prevents redundant work above. The canonical rebase form is `git rebase --onto <new-base> <old-base-tip> <child-branch>` — a plain `git rebase` will produce phantom conflicts against a squash-merged ancestor. The full sub-case breakdown (merged-ancestor / updated-ancestor / conflict-only) and the GitHub PR base retargeting steps (including the `gh api PATCH` REST fallback when `gh pr edit --base` fails) live in `references/conflict-resolution.md`.
5. **Per-PR checks and reviews.** Once cascades are settled, treat each open PR with normal failing-check classification, flaky retry budgets, and review-comment handling: see `references/per-pr-checks.md`.
6. **Report progress** as a compact table:
   ```
   #123 base→main      MERGED ✅
   #124 base→f/auth-1  GREEN  ⚙ rebasing onto main… done, pushed e3a91c
   #125 base→f/auth-2  PENDING CI on e3a91c
   #126 base→f/auth-3  DIRTY  ⏸ conflict in src/db/migrations/2024_05.sql — needs you
   ```
   Avoid dumping full check lists on every tick — only on state change.

After each successful rebase, `git push --force-with-lease` and move to the next PR up. Never `--force` without lease — a collaborator may have pushed.

## Rebase conflict resolution — summary

When `git rebase` reports conflicts, classify each conflicted file before touching it.

**Auto-resolve in place when the resolution is mechanically determined** (lockfiles → regenerate, whitespace → format, non-overlapping adjacent additions → take both, generated files → re-generate from source).

**Escalate when intent matters** (overlapping edits in logic, migrations, IaC, API schemas, deletes-vs-modify, same-line modifications in any file type including prose, >5 conflicting hunks, binaries, CI configs).

Full rules, file-type playbook, validation steps, and the squash-merge `--onto` carve-out: `references/conflict-resolution.md`.

When escalating, leave the rebase paused (do not `--abort`), report which PR is paused, the conflicted paths with a one-line summary, and recovery hints.

## Polling and idempotency

The skill is designed to be safely repeatable under **any** polling mechanism — invoke once for a one-shot tick, run under a fixed-interval loop (e.g. `/loop 2m`), a cron, a watch script, or simply re-invoke manually. A single tick must be **idempotent**: re-running it when nothing changed produces no work.

Idempotency relies on the snapshot file (see `references/snapshot-format.md`): always read it at tick start, write at tick end, and skip rebasing any PR whose head SHA matches the last record.

Cadence guidance when the model paces itself:
- Just pushed new SHAs: poll again in 60–90 s to catch the new CI quickly.
- Quietly waiting on CI: poll every 2–5 min.
- Steady-state green stack waiting on review: 5–15 min is fine.

## Git safety

- `git push --force-with-lease`, never `--force`.
- Never run destructive ops (`reset --hard`, `clean -fd`, branch deletes) without explicit user confirmation, even mid-rebase.
- Before checking out any stack branch, verify the worktree is clean. If there are unrelated uncommitted changes, stop and ask — the user may have in-progress work.
- If a rebase needs to bail, prefer `git rebase --abort` over `reset`.
- Note the original HEAD of each touched branch so you can guide the user to recover via reflog if something goes wrong.
- Do not delete branches automatically when their PR merges — leave that to the user or the repo's auto-delete setting.

## Stop conditions (strict)

Stop only when:

- Every PR in the stack is merged or closed.
- A conflict requires human judgment.
- A non-recoverable git or auth error (push rejected for reasons other than non-fast-forward, `gh` auth missing, repo permissions).
- The user explicitly interrupts.

When the remaining stack is fully green, mergeable, and review-clean, keep watching for late review comments — do not exit until everything has merged.

Do **not** stop because a single tick shows "no changes" — that is the steady state while CI runs.

## Output expectations

- Compact per-tick table (see step 6).
- One-time celebratory line when the bottom PR merges (`🎉 #123 landed — rebasing the rest…`).
- Final summary when everything merges: merged PR numbers, total flaky reruns used, conflicts the user resolved, final SHAs.
- When asking the user for help with a conflict, lead with the exact `git status` excerpt and suggested next steps — don't bury the ask.

## References

- `references/stack-discovery.md` — `gh` commands, walking pseudocode, edge cases.
- `references/merge-state-table.md` — `mergeStateStatus` interpretation.
- `references/snapshot-format.md` — snapshot file schema, location, first-tick exception.
- `references/conflict-resolution.md` — conflict classification rules, `--onto` sub-cases, retargeting, validation.
- `references/per-pr-checks.md` — CI failure classification, flaky retry budget, review-comment handling for each individual PR.
- `test-linked-prs.md` — end-to-end test scenarios.
