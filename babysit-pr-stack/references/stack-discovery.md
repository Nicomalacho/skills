# Stack Discovery

This doc covers how to walk a GitHub PR stack from any anchor point using only `gh` and `git`. No graphite/spr/ghstack required.

## Mental model

A stack is a linear chain of open PRs where each PR's `baseRefName` equals the previous PR's `headRefName`. The chain ends at the bottom when `baseRefName` is the repo's default branch (typically `main` or `master`).

```
PR #126  head: feature/auth-step-3   base: feature/auth-step-2
PR #125  head: feature/auth-step-2   base: feature/auth-step-1
PR #124  head: feature/auth-step-1   base: main
```

Bottom of stack = PR closest to `main`. Top of stack = PR furthest from `main`. Cascade rebases run **bottom→top** because each rebase changes the SHAs every PR above depends on.

## Resolving the default branch

Use this once at the start; cache the result for the session:

```bash
gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
```

## Resolving the anchor PR

From the current branch:

```bash
gh pr view --json number,headRefName,baseRefName,state,mergeStateStatus
```

If `gh pr view` errors with "no pull requests found", the current branch has no PR — ask the user which PR to anchor on.

From an explicit number or URL:

```bash
gh pr view <number-or-url> --json number,headRefName,baseRefName,state,mergeStateStatus
```

## Walking down (toward main)

While the current PR's `baseRefName` is not the default branch, find the parent PR:

```bash
gh pr list --state open --head <currentBaseRefName> \
  --json number,headRefName,baseRefName,state \
  --jq '.[0]'
```

`gh pr list --head <branch>` returns the open PR whose head is that branch. If it returns empty while `baseRefName` is still not the default branch, the stack is **loose at the bottom** — the branch this PR points at has no PR of its own. Surface this to the user; do not silently treat it as the bottom.

## Walking up (away from main)

For each PR, find children — PRs whose base is this PR's head:

```bash
gh pr list --state open --base <currentHeadRefName> \
  --json number,headRefName,baseRefName,state
```

If this returns more than one open PR, the stack **forks**. Surface the fork to the user with both branch names and let them pick which line to follow. Following the wrong fork rebases the wrong branches.

## Edge cases

- **Closed/merged PRs in the middle of the chain**: do not follow into closed PRs. If the chain has a gap (e.g. PR #125 was force-pushed to point at `main` directly while #126 still targets `feature/auth-step-2`), treat #126 as broken and surface it.
- **Renamed default branch** (`master` → `main`): always re-read `defaultBranchRef` rather than hardcoding.
- **Cross-fork PRs** (head in a fork, base in the upstream repo): `gh pr list --head` matches by branch name in the upstream repo's head index. If the user is rebasing across forks, ask before touching anything — push permissions differ.
- **Detached anchor**: user gives a PR number whose head branch isn't checked out anywhere locally. Fetch with `git fetch origin <headRefName>:<headRefName>` before attempting any local rebase.

## Walking algorithm (pseudocode)

```
default_branch = gh repo view ... defaultBranchRef.name
anchor = resolve_anchor(input)

# Walk down
chain = [anchor]
while chain[0].baseRefName != default_branch:
    parent = gh pr list --head chain[0].baseRefName --state open
    if not parent:
        warn("loose base"); break
    chain.insert(0, parent)

# Walk up
while True:
    children = gh pr list --base chain[-1].headRefName --state open
    if not children: break
    if len(children) > 1:
        ask_user_which_fork(children); break
    chain.append(children[0])

return chain  # bottom→top
```

## Confirming with the user

Always print the discovered chain before acting on it:

```
Discovered stack (bottom → top):
  1. #124  feature/auth-step-1  →  main         OPEN  GREEN
  2. #125  feature/auth-step-2  →  feature/auth-step-1  OPEN  PENDING CI
  3. #126  feature/auth-step-3  →  feature/auth-step-2  OPEN  DIRTY (conflicts)
```

Wait for explicit confirmation only if you suspect a fork or loose base; otherwise proceed.
