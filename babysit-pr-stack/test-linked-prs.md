# Test Scenarios — Linked PRs

Scenarios for exercising `babysit-pr-stack` against real or sandboxed stacked PRs. Each scenario describes the setup, the trigger event, and what the skill should do.

The scenarios are intentionally written so you can either (a) reproduce them on a real GitHub repo as smoke tests, or (b) feed them as prompts to an eval subagent that mocks `gh` responses.

---

## Scenario 1 — Plain three-PR stack, bottom merges cleanly

### Setup

```
main ──── A ──── B ──── C
         #100   #101   #102
```

- `#100` head=`stack/a`, base=`main`
- `#101` head=`stack/b`, base=`stack/a`
- `#102` head=`stack/c`, base=`stack/b`
- All green CI. No conflicts. No review feedback pending.

### Trigger

`#100` is merged via GitHub UI. GitHub auto-retargets `#101.base` from `stack/a` to `main`.

### Expected skill behavior

1. Discovers stack `#100 → #101 → #102` before acting.
2. Detects `#100` merged on next tick.
3. Rebases `stack/b` onto `origin/main`, no conflicts, `git push --force-with-lease origin stack/b`.
4. Rebases `stack/c` onto the new `stack/b` head, no conflicts, force-with-lease push.
5. Continues polling `#101` and `#102` until each turns green and merges.
6. Final summary lists all three merged with their final SHAs.

### Failure modes to watch for

- Skill rebases top-down instead of bottom-up.
- Skill uses `git push --force` without `--with-lease`.
- Skill stops after the bottom merges instead of cascading.

---

## Scenario 2 — Lockfile conflict on cascade

### Setup

```
main ──── A ──── B
         #200   #201
```

- `#200` modifies `src/auth.ts` and adds a dependency → `package-lock.json` updated.
- `#201` modifies `src/billing.ts` and adds a *different* dependency → `package-lock.json` also updated.
- Both PRs green individually.

### Trigger

`#200` merges. Rebasing `#201` onto main will conflict on `package-lock.json`.

### Expected skill behavior

1. During rebase, classifies `package-lock.json` as a lockfile conflict.
2. Does **not** hand-merge the conflict markers.
3. Deletes `package-lock.json`, runs `npm install` (or detected package manager), `git add package-lock.json`, `git rebase --continue`.
4. Pushes with `--force-with-lease`.
5. Reports the regeneration step to the user, not just "rebased".

### Failure modes to watch for

- Skill tries to manually pick `<<<<<<<` / `>>>>>>>` blocks in the lockfile.
- Skill regenerates from the wrong package manager (e.g. `yarn` when the repo uses `pnpm`).
- Skill commits without re-running install, leaving an inconsistent lockfile.

---

## Scenario 3 — Migration conflict requires escalation

### Setup

```
main ──── A ──── B
         #300   #301
```

- `#300` adds migration `db/migrations/2024_05_01_users.sql`.
- `#301` adds migration `db/migrations/2024_05_01_orgs.sql` *and* edits `db/migrations/2024_05_01_users.sql` (same filename, different content).

### Trigger

`#300` merges. Rebasing `#301` produces a conflict in `db/migrations/2024_05_01_users.sql`.

### Expected skill behavior

1. Classifies the conflict as a migration file → **does not auto-resolve**.
2. Leaves the rebase paused (does not `--abort`).
3. Reports to the user:
   - Which PR is paused (`#301`).
   - The conflicted path with a one-line "migration file — ordering matters" note.
   - The `git status` excerpt.
   - Recovery hints (`git rebase --abort` to roll back; edit + `git add` + `--continue` to take over).
4. Continues monitoring other open PRs in the stack while waiting.

### Failure modes to watch for

- Skill picks `--theirs` or `--ours` on a migration.
- Skill silently aborts the rebase instead of leaving it paused.
- Skill stops polling everything because one PR is paused.

---

## Scenario 4 — Forked stack

### Setup

```
main ──── A ────┬──── B
                │    #401
                └──── C
                     #402
```

- `#400` head=`stack/a`, base=`main`.
- `#401` and `#402` both have base=`stack/a`. The stack forks above `#400`.

### Trigger

User says "watch my stack from #400".

### Expected skill behavior

1. During discovery, walks up from `#400` and finds two open child PRs.
2. Surfaces the fork to the user with both branch names and waits for them to pick which line to follow.
3. Does **not** silently pick one and rebase the other into oblivion.

### Failure modes to watch for

- Skill picks `#401` (lower number) without asking.
- Skill rebases both children as if they were sequential.

---

## Scenario 5 — `/loop` self-paced ticks during active rebase

### Setup

3-PR stack, bottom just merged, skill is mid-cascade.

### Trigger

`/loop /babysit-pr-stack` (no interval, model self-paces).

### Expected skill behavior

1. After a rebase + push, schedules the next tick within 60–90 s (CI is the next blocker, but the new SHA needs a fast first-look).
2. While idle and CI is running on every PR, ticks every 2–5 min.
3. Each tick is idempotent — if no PR changed state, no rebase or push is attempted.

### Failure modes to watch for

- Skill re-rebases a PR whose head SHA hasn't changed since last tick.
- Skill polls every 30 s while CI is running (wasteful).
- Skill schedules the next tick more than 10 min out after pushing, missing fast-cycle CI.

---

## Scenario 6 — Loose base / broken chain

### Setup

```
main ──── A      B
         #500   #501  (head=stack/b, base=stack/a, but #500 was force-pushed to point at main)
```

- `#501.base = stack/a` but `stack/a` no longer has an open PR with that head (it was retargeted or closed).

### Trigger

User asks to watch `#501`.

### Expected skill behavior

1. During discovery, finds `#501.base = stack/a` but no open PR for `stack/a`.
2. Reports "loose base" to the user — does not silently assume it's the bottom of the stack.
3. Asks whether to retarget `#501.base` to `main` or wait.

---

## How to use these scenarios

- **Manual smoke test:** spin up a throwaway repo, recreate the stack with `gh pr create`, induce the trigger, and run the skill via Claude Code. Compare the behavior to the "Expected" section.
- **As eval prompts:** feed the scenario's prose description (plus any required setup commands) to a subagent that has access to a sandbox repo. Grade against the bullet list under "Expected skill behavior".
- **As regression checklist:** when iterating the skill, walk through each scenario mentally before declaring an iteration done. The lockfile and migration scenarios are the highest-leverage ones — they map to actual incidents.
