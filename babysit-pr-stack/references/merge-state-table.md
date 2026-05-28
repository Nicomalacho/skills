# `mergeStateStatus` Interpretation

GitHub's `mergeStateStatus` field on a PR has six values and they are not interchangeable. Each maps to a different action.

| Status | Meaning | Action |
|---|---|---|
| `DIRTY` | Merge conflicts against base | Rebase this PR onto its current base; auto-resolve safe conflicts per `conflict-resolution.md`, escalate the rest |
| `BEHIND` | Base advanced; mergeable but stale | Rebase onto the new base SHA (no conflict yet, just catching up) |
| `UNSTABLE` | Mergeable but at least one check non-success | Inspect failing/in-progress checks. If still running, **wait** — do not retry. If actually failed, classify like a single-PR babysitter (branch-related fix vs flaky retry). `UNSTABLE` alone is not a cascade trigger |
| `BLOCKED` | Branch-protection or required-review not satisfied | Wait. Surface reviews needed; never act |
| `UNKNOWN` | GitHub still computing | Wait one tick, re-check; do not act |
| `CLEAN` / `HAS_HOOKS` | Ready to merge | No cascade work; continue monitoring |

## Common misreadings

- **`UNSTABLE` ≠ `DIRTY`.** `UNSTABLE` is about checks, not conflicts. Rebasing in response to `UNSTABLE` is wasted work.
- **`UNKNOWN` is transient.** GitHub computes mergeability asynchronously after pushes and merges. Always re-check on the next tick rather than treating it as a permanent state.
- **`BEHIND` vs `DIRTY`.** Both mean "needs rebase", but `BEHIND` has no conflict — a plain rebase will succeed. `DIRTY` will hit conflicts.
- **`BLOCKED` is not your problem to fix.** It means a human review is required or branch protection isn't satisfied. Surface it; do not try to bypass.

## How to read it

```bash
gh pr view <n> --json mergeStateStatus,mergeable
```

The accompanying `mergeable` field is a yes/no/unknown alongside the more nuanced `mergeStateStatus`.
