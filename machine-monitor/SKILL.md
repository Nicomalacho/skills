---
name: machine-monitor
description: >
  Scan this Mac for resource pressure and runaway/orphaned dev processes
  (node/jest/vite/webpack/tsc/docker dev servers, duplicate port listeners,
  zombies, and feature-cli workspaces whose branch is already merged/deleted),
  classify each as keep / suspect / safe-to-kill with a reason, and — with
  confirm-before-every-kill — propose a numbered kill list and wait for an
  explicit yes/no before touching anything. Also surfaces non-destructive
  "optimize" suggestions. Designed to be driven by /loop (e.g.
  /loop 5m /machine-monitor). Use when asked to watch machine resources, find
  what's eating CPU/RAM, or clean up stale dev processes.
---

# machine-monitor

One iteration = one scan of the machine. Run recurring with:

```
/loop 5m /machine-monitor
```

A one-off `/machine-monitor` invocation works for testing. macOS only.

> ⚠️ **Kill policy: CONFIRM BEFORE EVERY KILL.** This skill NEVER kills,
> stops, or destroys anything on its own. It may only *read* system state and
> *propose* a numbered candidate list. Killing happens only after Nicolas
> replies with an explicit selection in the same iteration. If there is any
> ambiguity in his reply, do nothing and ask again.

> ⚠️ **Personalized skill.** The environment-facts table below is specific to
> Nicolas's machine (feature workspaces root, GitHub login, thresholds). Adjust
> before reuse on another machine.

## Hardcoded environment facts

| Fact | Value |
|---|---|
| Feature workspaces root | `~/features/` (each is `~/features/<dir>/<repo-slug>`) |
| feature-cli | `feature list` (running services), `feature prune` (stale = merged/deleted branch), `feature stop <dir>` (clean shutdown), `feature ports <dir>` |
| Nicolas's GitHub login | `Nicomalacho` |
| State file | `~/.claude/skills/machine-monitor/state.json` |
| Snooze window | A declined candidate is not re-surfaced for **2 hours** unless it gets materially worse (see step 5) |
| Dev-process signatures | `node`, `jest`, `vitest`, `webpack`, `next`, `vite`, `esbuild`, `tsc`, `ts-node`, `nodemon`, `bun`, `docker`, `Docker`, `qemu` |

### Thresholds (tunable)

| Signal | Threshold |
|---|---|
| Sustained CPU hog | a process > **50% CPU** AND `etime` > **5 min** |
| Memory hog | a single process RSS > **1.5 GB** |
| System load | 1-min load average > **cores × 1.5** |
| Memory pressure | `memory_pressure` not reporting "normal" / free pages low |

## Preconditions (check once per iteration, fail fast)

- macOS with `ps`, `vm_stat`, `memory_pressure`, `lsof` available. If not macOS, stop and say so.
- `feature`, `gh`, and `git` on PATH (orphan detection degrades gracefully without them — still report raw hogs, just skip the merged/deleted-branch check and note it).

## Iteration algorithm

### 1. Load state

Read `~/.claude/skills/machine-monitor/state.json`:

```json
{
  "snoozed": {
    "<signature>": { "until_epoch": 1750000000, "last_metric": "1.2GB", "reason": "declined" }
  },
  "killed_log": [
    { "epoch": 1749990000, "signature": "node ~/features/red-3680", "how": "feature stop" }
  ]
}
```

`<signature>` is a **stable** identity for a candidate — use `command-basename + workspace-dir` (NOT the PID, which changes). If the file is missing, start with `{"snoozed":{},"killed_log":[]}`.

### 2. Snapshot system health

```bash
cores=$(sysctl -n hw.ncpu)
sysctl -n vm.loadavg                 # -> { 6.12 5.88 5.40 }
memory_pressure 2>/dev/null | tail -3
ps -Aro pid,ppid,%cpu,%mem,rss,etime,command | head -25   # top by CPU
ps -Amo pid,ppid,%cpu,%mem,rss,etime,command | head -25   # top by memory
```

Note load vs `cores × 1.5` and whether memory pressure is normal. This goes in
the report header regardless of whether there are kill candidates.

### 3. Build the candidate set

Collect processes that match any rule below. For each, capture pid, command, rss, %cpu, etime, and (if resolvable) its feature workspace dir.

**a. Orphaned feature-cli dev servers (highest-value, usually safe-to-kill).**
   - Run `feature list` to see workspaces with running (non-`stopped`) services.
   - Run `feature prune --help` once; if it supports a dry-run/list flag, use it to get the set of **stale** workspaces (branch merged or deleted upstream). Otherwise, for each running workspace resolve its branch and check:
     ```bash
     gh pr list --head <branch> --state all --json state,number --jq '.[0].state'   # MERGED/CLOSED?
     git -C ~/features/<dir>/<repo-slug> ls-remote --exit-code origin <branch> >/dev/null 2>&1 || echo "branch gone"
     ```
   - A running service whose branch is **MERGED/CLOSED or deleted upstream** is an orphan → `safe-to-kill`, reason e.g. `branch merged 3d ago`.

**b. Sustained CPU hogs** — process over the CPU threshold for over the etime threshold. Dev-signature processes are `suspect`; if tied to a merged/deleted branch, `safe-to-kill`; otherwise `suspect` (might be a real build/test in progress — never auto-anything).

**c. Memory hogs** — RSS over threshold. Same classification logic as (b). Note Docker/qemu separately (killing Docker Desktop's VM is rarely what he wants — classify `suspect`, suggest `optimize` instead).

**d. Duplicate port listeners** — find dev servers double-bound:
   ```bash
   lsof -nP -iTCP -sTCP:LISTEN | grep -Ei 'node|vite|next|webpack|esbuild'
   ```
   If two processes serve the same logical dev port (e.g. two Vite on `:5173`), the **older / 0%-CPU** one is `safe-to-kill` (reason `duplicate :5173, idle`).

**e. Zombies / defunct** — `ps` rows with STAT containing `Z` or command `<defunct>` → `safe-to-kill` (reason `defunct`), though usually the fix is killing the parent; note the ppid.

### 4. Apply snooze + classify

- Drop any candidate whose `<signature>` is in `state.snoozed` and still within its `until_epoch`, UNLESS it got materially worse than `last_metric` (e.g. RSS grew > 1.5× or CPU climbed a lot) — then re-surface it.
- Final classes: `safe-to-kill` (unambiguous: orphan / duplicate-idle / defunct) and `suspect` (judgement call: hot process that might be real work).

### 5. Present candidates and WAIT (the confirm gate)

If there are **no** candidates, skip to step 7 with a quiet report.

Otherwise print a single numbered list, `safe-to-kill` first, each with reason and the exact reclaim action. Prefer the **cleanest** shutdown:
- feature workspace → `feature stop <dir>` (or `feature destroy <dir>` / `feature prune` if it's an orphan he'll never reuse).
- standalone process → `kill <pid>` (graceful). Only escalate to `kill -9` if a follow-up scan shows it survived, and only with fresh confirmation.

Format:

```
System: load 9.1 / 8 cores (HIGH) · memory pressure: warn

Kill candidates:
  1. [safe]    node  ~/features/feature-red-3680/snappr.server (PR merged 3d ago)  1.2GB
               → feature stop feature-red-3680
  2. [safe]    vite  :5173 duplicate, idle 0% cpu, pid 50122
               → kill 50122
  3. [suspect] tsc   pid 41233, 182% cpu for 24m — could be a real build
               → kill 41233

Kill which? (e.g. "1,2" / "all safe" / "all" / "none" / "snooze 3")
```

Then **stop and wait for Nicolas's reply.** Do not proceed until he answers.

Interpreting the reply:
- numbers / `all safe` / `all` → execute those actions, preferring the clean command shown. Run them, confirm each succeeded (re-check the pid/service is gone), and append to `killed_log`.
- `none` → kill nothing; add every listed candidate's signature to `snoozed` for the 2h window (so the loop stops nagging).
- `snooze N` / `snooze 1,3` → snooze just those; act on / leave the rest per the rest of the reply.
- anything ambiguous → do nothing, restate the list, ask again.

### 6. Optimize suggestions (non-destructive, never auto-applied)

After the kill gate, if relevant, add a short "Optimize" section — advice only, no action:
- many idle feature services running at once → "consider `feature stop` on N stopped-but-live workspaces to reclaim ~X GB".
- Docker/qemu large RSS → "Docker VM using X GB; `docker system prune` or lower the VM memory in Docker Desktop".
- repeated duplicate-port collisions → "stale dev server keeps respawning; check the workspace's post-init".

### 7. Save state

- Persist `snoozed` (prune entries past their `until_epoch`) and `killed_log` (keep last 50).
- Write the file back.

### 8. Report

End with a short summary, one line per outcome:

- `Healthy — load 5.1/8, memory normal, no runaway or orphaned dev processes.` — quiet iteration.
- `Killed 2 (feature stop feature-red-3680, kill 50122); 1 suspect snoozed 2h.`
- `3 candidates surfaced; awaiting your pick.` — when paused on the gate.
- `gh unavailable — reported raw hogs only, skipped merged-branch orphan check.`

## Gotchas

- **PIDs are not stable across iterations** — always key snooze/state on the
  command+workspace signature, never the PID. Re-resolve PIDs fresh each scan.
- **Never kill by name globally** (no `pkill node`) — a stray match could take
  down a real dev server or this very session. Always target a specific PID or
  use `feature stop <dir>` for a known workspace.
- **Don't kill your own toolchain** — exclude the running `claude`/`node`
  process of THIS session, the `cmux` server, and anything under its process
  tree. When unsure whether a node process is this session, classify `suspect`,
  never `safe`.
- **`feature stop` is cleaner than `kill`** for anything feature-cli started —
  it frees the port allocation and stops sibling services. Prefer it.
- **Docker Desktop**: killing `com.docker.*` / `qemu` can corrupt the VM —
  always `suspect` + optimize-suggest, never `safe-to-kill`.
- `memory_pressure` output varies by macOS version; if parsing is unreliable,
  fall back to `vm_stat` free/inactive page counts and report qualitatively.
- The confirm gate means an unattended `/loop` will simply pause and wait at a
  candidate list until Nicolas is back — that is intended, not a hang.
```
