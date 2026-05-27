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
3. **Walk up** (away from `main`): for each PR, look up open PRs whose `baseRefName` equals this PR's `headRefName`. Each becomes the next level up. When multiple children share the same parent you have one of two patterns — and they need different handling:
   - **Fan-out** (siblings meant to land in parallel). Typical signs: similar title prefixes for the same ticket (e.g. all `test(...): ... [RED-3668]`), all targeting the same base PR, and no further descendants above any of them. Treat the group as a single layer above the parent: manage all children in parallel. They are independent above the merge point — once the shared parent lands, every child rebases onto the new base (typically the repo default) in any order.
   - **True fork** (competing alternatives where only one is meant to land). Signs: children with conflicting goals/titles, or children that themselves have descendants above them. Surface the fork to the user with branch names and let them pick which line to follow.
   - When the pattern is ambiguous, **ask**: show the children with their titles and ask "manage in parallel, or pick one?". Default to fan-out only when the signals are strong (matching ticket prefix, similar titles, no grandchildren).
4. Print the discovered stack to the user before acting on it. Stacks are easy to misidentify; a wrong order will corrupt history. For fan-outs, show the parent on its own line and the parallel children indented underneath.

Detailed `gh` commands and edge cases live in `references/stack-discovery.md`.

## Per-tick workflow

Each polling tick (whether you are in `/loop` or polling manually) does the following, in order:

1. **Refresh the stack list.** PRs may have merged or closed since last tick. Re-run discovery on the current top-of-stack if any anchor has disappeared.
2. **Snapshot every PR** bottom→top. For each, capture: state (open/merged/closed), head SHA, base branch, mergeability, failing checks, new review items since last tick. Use `gh pr view <n> --json state,mergeable,mergeStateStatus,headRefOid,baseRefName,reviewDecision,statusCheckRollup,reviews,comments`.
3. **Detect cascade triggers** by comparing to the previous tick (or initial baseline) and by reading each PR's `mergeStateStatus`. The status values are not interchangeable — interpret them like this:

   | Status | Meaning | Action |
   |---|---|---|
   | `DIRTY` | Merge conflicts against base | Rebase this PR onto its current base; auto-resolve safe conflicts, escalate the rest |
   | `BEHIND` | Base advanced; mergeable but stale | Rebase onto the new base SHA (no conflict yet, just catching up) |
   | `UNSTABLE` | Mergeable but at least one check non-success | Inspect failing/in-progress checks. If still running, **wait** — do not retry. If actually failed, classify like `babysit-pr` (branch-related fix vs flaky retry). UNSTABLE alone is not a cascade trigger |
   | `BLOCKED` | Branch-protection / required-review not satisfied | Wait. Surface reviews needed; never act |
   | `UNKNOWN` | GitHub still computing | Wait one tick, re-check; do not act |
   | `CLEAN` / `HAS_HOOKS` | Ready to merge | No cascade work; continue monitoring |

   Beyond `mergeStateStatus`, also compare to the previous snapshot:
   - A previously-open PR is now **merged** → its children need their base retargeted (GitHub auto-retargets to the merged PR's base, but the local branches still need rebasing onto the new base SHA).
   - A previously-open PR has a **new head SHA** (the user or you pushed to it) → every PR above it in the stack needs to be rebased onto the new commits.
4. **Act on the lowest unresolved trigger first.** Cascades propagate, so handling the bottom keeps the upper PRs from doing redundant work.

   The form of the rebase command matters. A naive `git rebase origin/<new-base>` *replays* every commit reachable from the child but not from the new base — including the merged ancestor's pre-squash commits, which will conflict against the squash. Use `--onto` to drop the old-base segment cleanly:

   ```bash
   git fetch origin
   git checkout <child-branch>
   git rebase --onto <new-base> <old-base-tip> <child-branch>
   # e.g. git rebase --onto origin/main origin/test/stack-1 test/stack-2
   ```

   Where:
   - `<new-base>` = the branch the child should now sit on top of (usually `origin/main` after the parent merges, or the ancestor's new head SHA if the ancestor was updated rather than merged).
   - `<old-base-tip>` = the tip of the branch the child used to sit on (i.e. the merged ancestor's pre-merge head, or the ancestor's previous SHA). Captured from the prior-tick snapshot or `gh pr view <ancestor> --json mergeCommit,headRefOid` before/after the change.
   - `<child-branch>` = the PR head branch you're rebasing.

   `--onto` drops the commits between the old base and the child cleanly, so a squash-merged ancestor never produces phantom conflicts in CHANGELOGs, lockfiles, or anywhere else the squashed commits modified the same files.

   Sub-cases:
   - **Merged-ancestor case:** new-base = the merged PR's base (default branch after merge). Old-base-tip = `origin/<merged-PR-head-branch>` (still present unless the user deleted it).
   - **Updated-ancestor case:** new-base = the ancestor's new head SHA. Old-base-tip = the ancestor's previous head SHA from the prior snapshot.
   - **Conflict-only case** (`DIRTY` with no ancestor change): a plain `git rebase origin/<base>` is fine — there's no segment to drop because the base hasn't moved out from under the PR; conflicts here are real overlapping edits, not replay artifacts.

   After each successful rebase, `git push --force-with-lease` and move to the next PR up. Never `--force` without lease — another collaborator may have pushed.

   **Retarget the GitHub PR base when needed.** GitHub auto-retargets a child PR's base only when the merged parent's head branch is **deleted**. If the user kept the branch (common when settings preserve branches or the merge was via API with `delete-branch=false`), the child PR will still show `base = <merged-parent-head>` on GitHub even though you've already rebased it onto `main` locally. Retarget it explicitly:

   ```bash
   gh pr edit <child-pr> --repo <owner>/<repo> --base <new-base>
   ```

   If `gh pr edit` exits non-zero with a GraphQL deprecation error (older repos with classic Projects emit a noisy warning that crashes the command), fall back to the REST API directly:

   ```bash
   gh api -X PATCH repos/<owner>/<repo>/pulls/<child-pr> -f base=<new-base>
   ```

   The REST PATCH applies cleanly and ignores the GraphQL noise.
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

A single tick must be **idempotent** — if /loop fires it twice, the second tick should be a no-op when nothing changed. Use the prior-tick snapshot to detect changes; never re-rebase a PR whose head SHA matches the last tick's record.

**Snapshot file format.** Persist at `/tmp/babysit-pr-stack-<owner>-<repo>.json`. Schema:

```json
{
  "anchor": 3,
  "default_branch": "main",
  "stack": [
    {"number": 1, "head": "test/stack-1", "base": "main",          "head_sha": "f01a4f7…", "state": "OPEN", "merge_state": "CLEAN"},
    {"number": 2, "head": "test/stack-2", "base": "test/stack-1",  "head_sha": "8965a71…", "state": "OPEN", "merge_state": "CLEAN"},
    {"number": 3, "head": "test/stack-3", "base": "test/stack-2",  "head_sha": "c72934c…", "state": "OPEN", "merge_state": "CLEAN"}
  ],
  "last_tick_at": "2026-05-27T13:14:00Z"
}
```

Read this file at the **start** of every tick. If missing (first run, or a new anchor), skip diffing and treat the current snapshot as baseline. Write at the **end** of every tick, replacing the prior contents. Diff by comparing `head_sha` and `state` per PR; a SHA change or `OPEN → MERGED` transition is a cascade trigger. Empty/zero values for `reviewDecision` or `statusCheckRollup` are normal when no reviewers/CI are configured — treat them as the same as "no signal", not as missing data.

**First-tick exception.** "Treat current snapshot as baseline" is correct for everything *except* already-merged ancestors. If you find a PR with `state: MERGED` whose head branch is still listed as the `baseRefName` of a downstream OPEN PR, that is a cascade trigger even on the first tick — the merge happened before you started watching, but the work to propagate it has not been done yet. Process it the same as if you had observed the merge transition live. Without this exception, anchoring the skill on a stack where the bottom merged five minutes before you ran would silently skip the cascade.

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
