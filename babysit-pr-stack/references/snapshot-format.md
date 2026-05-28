# Snapshot File Format

The skill persists a small state file between ticks so each invocation can diff the current PR state against the previous one. This is what makes a single tick idempotent — re-running it when nothing has changed produces no work.

## Location

```
${XDG_STATE_HOME:-$HOME/.cache}/babysit-pr-stack/<owner>-<repo>.json
```

Examples:
- Linux with XDG set: `~/.local/state/babysit-pr-stack/Nicomalacho-skills.json`
- macOS / no XDG set: `~/.cache/babysit-pr-stack/Nicomalacho-skills.json`

Avoid `/tmp` — it's world-readable on multi-user hosts and would leak PR metadata. Create the parent directory on first write (`mkdir -p`).

## Schema

```json
{
  "anchor": 3,
  "default_branch": "main",
  "stack": [
    {"number": 1, "head": "test/stack-1", "base": "main",          "head_sha": "f01a4f7…", "state": "OPEN",   "merge_state": "CLEAN"},
    {"number": 2, "head": "test/stack-2", "base": "test/stack-1",  "head_sha": "8965a71…", "state": "OPEN",   "merge_state": "CLEAN"},
    {"number": 3, "head": "test/stack-3", "base": "test/stack-2",  "head_sha": "c72934c…", "state": "OPEN",   "merge_state": "CLEAN"}
  ],
  "last_tick_at": "2026-05-27T13:14:00Z"
}
```

Required fields per PR: `number`, `head`, `base`, `head_sha`, `state`, `merge_state`. Other fields can be added (e.g. `mergeCommit` for already-merged PRs) without breaking diff logic.

## Read / write semantics

- **Read at the start of every tick.** If the file is missing (first run, or a new anchor), skip diffing and treat the current snapshot as baseline.
- **Write at the end of every tick**, replacing the prior contents atomically (write to a temp file in the same directory, then rename).
- **Diff** by comparing `head_sha` and `state` per PR. A SHA change or `OPEN → MERGED` transition is a cascade trigger.
- **Empty / zero values** for `reviewDecision` or `statusCheckRollup` (e.g. no reviewers / no CI configured) are normal — treat them as "no signal", not as missing data.
- **Keep merged PRs in the snapshot** for one tick after they merge so the next tick can still diff against them. After that they can be pruned.

## First-tick exception

"Treat current snapshot as baseline" is correct for everything **except already-merged ancestors**. If you find a PR with `state: MERGED` whose head branch is still listed as the `baseRefName` of a downstream open PR, that is a cascade trigger even on the first tick — the merge happened before you started watching, but the propagation work has not been done yet.

Process this the same as if you had observed the merge transition live. Without this exception, anchoring the skill on a stack where the bottom merged five minutes before you ran would silently skip the cascade.

## Why a state file at all

The skill could rederive everything from GitHub on every tick, but two things require comparing to a previous tick:
1. **Detecting that a PR's head SHA changed.** Useful both as a cascade trigger and to avoid re-rebasing a PR whose head matches the last record.
2. **Capturing the old-base-tip** required by the canonical `git rebase --onto <new-base> <old-base-tip> <branch>` form. Once the parent has merged or moved, its old SHA is no longer the tip of any branch and must come from the prior snapshot.
