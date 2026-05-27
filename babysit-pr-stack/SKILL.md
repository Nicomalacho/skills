---
name: babysit-pr-stack
description: Babysit a stack of dependent GitHub pull requests end-to-end — discover every PR in the stack from a starting branch or PR, poll each one's CI / review / mergeability, and cascade-rebase children automatically when an ancestor lands or moves. Resolves simple rebase conflicts in place (lockfiles, import collisions, non-overlapping adjacent edits, whitespace) and surfaces complex ones with diagnosis. Use this whenever the user asks to watch, monitor, babysit, manage, land, or unblock a stacked PR set, a chain of PRs, dependent branches, a "stack of changes", or says things like "PR X is on top of PR Y" or "rebase the stack when the bottom merges" — even if they don't say the word "stack" explicitly. Prefer this skill over single-PR babysitting whenever more than one open PR is chained head→base.
---

# Stacked PR Babysitter

## Objective
Drive a stack of dependent GitHub PRs to a clean landing — bottom merges, children automatically rebase onto the new base, conflicts are resolved when safe, and CI/review state is monitored across every PR continuously.

This skill is the multi-PR cousin of `babysit-pr`. Reuse the single-PR patterns from that skill for each individual PR; this skill adds the cross-PR coordination on top.

## When to use

Use this skill when **any** of the following is true:

- The user explicitly mentions a stack, chain, train, or series of PRs.
- The current branch or anchor PR has another open PR's head as its base (i.e. its `base` is not the repo's default branch).
- The user asks to "rebase the stack when X merges" or "keep the stack green".
- More than one open PR exists where one's `base` equals another's `head`.

For an isolated single PR (base == default branch, no children), defer to `babysit-pr` instead — its polling and review logic is leaner.

## Inputs

Accept any of:

- **No argument** — discover the stack from the current branch. Resolve the PR for the current branch with `gh pr view --json number,baseRefName,headRefName,state`, then walk the stack.
- **A single anchor PR** (number or URL) — discover the rest of the stack by walking up and down from there.
- **An explicit ordered list** of PR numbers (bottom→top). Trust the order the user gave you.

## Stack discovery

Build the ordered list bottom→top before doing anything else. Order matters because rebases must cascade in that direction.

1. Resolve the anchor PR.
2. **Walk down** (toward `main`): while the current PR's `baseRefName` is not the repo default branch, look up the open PR whose `headRefName` equals the current `baseRefName`. That parent PR is one level lower. Stop when `baseRefName` is the default branch (or there is no matching open PR — record this as "base is loose"; flag it to the user).
3. **Walk up** (away from `main`): for each PR, look up open PRs whose `baseRefName` equals this PR's `headRefName`. Each becomes the next level up. If multiple children share the same parent, the stack actually forks — surface that and ask the user which branch to follow (do not silently pick one).
4. Print the discovered stack to the user before acting on it. Stacks are easy to misidentify; a wrong order will corrupt history.

Detailed `gh` commands and edge cases live in `references/stack-discovery.md`.

## Per-tick workflow

Each polling tick (whether you are in `/loop` or polling manually) does the following, in order:

1. **Refresh the stack list.** PRs may have merged or closed since last tick. Re-run discovery on the current top-of-stack if any anchor has disappeared.
2. **Snapshot every PR** bottom→top. For each, capture: state (open/merged/closed), head SHA, base branch, mergeability, failing checks, new review items since last tick. Use `gh pr view <n> --json state,mergeable,mergeStateStatus,headRefOid,baseRefName,reviewDecision,statusCheckRollup,reviews,comments`.
3. **Detect cascade triggers** by comparing to the previous tick (or initial baseline):
   - A previously-open PR is now **merged** → its children need their base retargeted (GitHub auto-retargets to the merged PR's base, but the local branches still need rebasing onto the new base SHA).
   - A previously-open PR has a **new head SHA** (the user or you pushed to it) → every PR above it in the stack needs to be rebased onto the new commits.
   - A PR shows `mergeStateStatus` of `DIRTY` (conflicts) → that specific PR needs a rebase.
4. **Act on the lowest unresolved trigger first.** Cascades propagate, so handling the bottom keeps the upper PRs from doing redundant work.
   - **Merged-ancestor case:** for each child above the merged PR, fetch, checkout the child's head branch, `git rebase origin/<new-base>`. If conflicts arise, follow the resolution rules below.
   - **Updated-ancestor case:** same as above, but rebase onto the ancestor's new head SHA.
   - **Conflict-only case:** rebase the dirty PR onto its current base.
   After each successful rebase, `git push --force-with-lease` and move to the next PR up. Never `--force` without lease — another collaborator may have pushed.
5. **Per-PR babysitting.** Once cascades are settled, treat each open PR like `babysit-pr` would: classify failing checks, retry flakies (budget of 3), surface review comments, fix branch-related failures. Do this top-down for visibility but bottom-up for fix priority (a failing bottom PR blocks everything above it).
6. **Report progress** as a compact table:
   ```
   #123 base→main      MERGED ✅
   #124 base→f/auth-1  GREEN  ⚙ rebasing onto main… done, pushed e3a91c
   #125 base→f/auth-2  PENDING CI on e3a91c
   #126 base→f/auth-3  DIRTY  ⏸ conflict in src/db/migrations/2024_05.sql — needs you
   ```
7. **Decide whether to continue.** See "Stop conditions" below.

## Rebase conflict resolution

When `git rebase` reports conflicts, classify each conflicted file before touching it. The full classification rules live in `references/conflict-resolution.md`; the summary:

**Auto-resolve in place when safe:**

- **Lockfiles** (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `Cargo.lock`, `poetry.lock`, `Gemfile.lock`, `go.sum`): delete the conflicted file and regenerate via the project's package manager. Do not hand-merge lockfile diffs.
- **Pure whitespace** conflicts: take the version that matches the project's formatter; run the formatter if uncertain.
- **Non-overlapping adjacent edits** where both sides added new lines in the same block but at clearly different positions (e.g. both added a new import on adjacent lines): apply both sides in order.
- **Generated files** (build artifacts, snapshots that the project regenerates from source): regenerate from the source-of-truth rather than merging.

**Stop and surface to the user when:**

- The conflict overlaps in business logic (function bodies, conditionals, control flow).
- The file is a database migration, infrastructure-as-code, or API schema.
- One side deleted a file the other side modified.
- The semantic intent of the two changes is unclear from the diff.
- More than ~5 hunks conflict in a single file, even if each individual hunk looks simple — the cognitive load shifts the safety margin past where the model should act alone.

When escalating, report:
- Which PR's rebase is paused.
- The conflicted paths and a one-line summary of each.
- A `git rebase --abort` recovery hint so the user can decide whether to roll back or take over.

Leave the rebase in its conflicted state. Do not abort it for the user — they may want to inspect.

## /loop integration

This skill is designed for use under `/loop`. Two patterns:

- **Fixed interval** (recommended when CI is the bottleneck): `/loop 2m /babysit-pr-stack` — runs a full tick every 2 minutes.
- **Self-paced** (recommended when actively rebasing): invoke without an interval; let the model schedule the next tick based on what it observed. If a rebase just pushed new SHAs, poll sooner (60–90 s). If everything is quietly waiting on CI, poll every 2–5 min.

A single tick must be **idempotent** — if /loop fires it twice, the second tick should be a no-op when nothing changed. Use the prior-tick snapshot (kept in conversation memory or written to `/tmp/babysit-pr-stack-<repo>-state.json`) to detect changes; never re-rebase a PR whose head SHA matches the last tick's record.

## Git safety

- Use `git push --force-with-lease`, never `--force`.
- Never run destructive ops (`reset --hard`, `clean -fd`, branch deletes) without explicit user confirmation, even mid-rebase.
- Before checking out any stack branch, verify the worktree is clean. If there are unrelated uncommitted changes, stop and ask — the user may have in-progress work.
- If you started a rebase and need to bail, prefer `git rebase --abort` over `reset`. Aborting leaves no residue.
- Keep a mental note of the original HEAD of each branch you touched so you can guide the user to recover if something goes wrong (e.g. `git reflog show <branch>`).
- Do not delete branches automatically when their PR merges — leave that to the user or the repo's auto-delete setting.

## Stop conditions (strict)

Stop only when one of these is true:

- **Every PR in the stack is merged or closed.** Final summary, then stop.
- **The remaining stack is fully green, mergeable, and review-clean** — at this point keep watching (like `babysit-pr`) for late review comments, but do not exit. Stop only when merged.
- **A conflict requires human judgment** (see escalation rules above).
- **A non-recoverable git or auth error** (push rejected for reasons other than non-fast-forward, `gh` auth missing, repo permissions).
- **The user explicitly interrupts.**

Do **not** stop because a single tick shows "no changes" — that is the normal steady state while CI runs.

## Output expectations

- Compact per-tick table (see step 6 above). Avoid dumping full check lists on every tick — only when something changes.
- One-time celebratory line when the bottom PR merges (`🎉 #123 landed — rebasing the rest…`).
- Final summary when everything merges: list of merged PR numbers, total flaky reruns used, any conflicts the user resolved, and the final SHAs.
- When asking the user for help with a conflict, lead with the exact `git status` excerpt and the suggested next steps — do not bury the ask.

## References

- `references/stack-discovery.md` — `gh` commands and walking algorithm.
- `references/conflict-resolution.md` — full conflict classification rules and per-file-type strategies.
- The single-PR cousin: `babysit-pr` skill — use its CI classification, review-comment handling, and polling cadence for each individual PR within the stack.
