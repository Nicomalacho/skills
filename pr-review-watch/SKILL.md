---
name: pr-review-watch
description: >
  Poll Slack #dev-pr-reviews for new messages mentioning Nicolas with a GitHub
  PR link, and for each PR spin up a feature-cli workspace, a cmux workspace
  with a Claude Code session pre-prompted to /review the PR, and a browser tab
  on the PR. Designed to be driven by /loop (e.g. /loop 5m /pr-review-watch).
  Use when asked to watch/poll dev-pr-reviews or auto-start PR review sessions.
---

# pr-review-watch

One iteration = one poll of #dev-pr-reviews. Run recurring with:

```
/loop 5m /pr-review-watch
```

A one-off `/pr-review-watch` invocation works for testing.

> ⚠️ **WARNING — personalized skill.** The "Hardcoded environment facts" table
> below is specific to Nicolas's machine and accounts (Slack channel + user ID,
> GitHub login, feature-cli paths). If you installed this skill from the
> [Nicomalacho/skills](https://github.com/Nicomalacho/skills) repo, you MUST
> replace those values with your own before running it — otherwise it will
> watch the wrong Slack channel, match the wrong mentions, and check PR
> approvals against the wrong GitHub user. Find your Slack user ID via the
> Slack MCP tools, your channel ID via `slack_search_channels`, and your
> GitHub login via `gh auth status`.

## Hardcoded environment facts

| Fact | Value |
|---|---|
| Slack channel #dev-pr-reviews | `GPZ71UN5B` (private channel) |
| Nicolas's Slack user ID | `URX2NBZQD` — mentions appear as `<@URX2NBZQD>` in raw message text |
| Nicolas's GitHub login | `Nicomalacho` (used for the "approved by me" check) |
| State file | `~/.claude/skills/pr-review-watch/state.json` |
| Feature workspaces root | `~/features/` |
| feature-cli repo configs | `~/.config/feature-cli/repos/` (config name == GitHub repo name, e.g. `snappr.server`) |

## Preconditions (check once per iteration, fail fast)

- `cmux ping` must succeed. The cmux socket only accepts callers inside cmux's
  process tree — if this fails, stop the iteration and tell the user this
  session must run inside cmux.
- `gh auth status` must pass (needed by `feature from-pr` and branch lookup).
- The Slack MCP plugin must be connected (`mcp__plugin_slack_slack__*` tools available).

## Iteration algorithm

### 1. Load state

Read `~/.claude/skills/pr-review-watch/state.json`:

```json
{
  "last_ts": "1749480000.000100",
  "processed": {
    "https://github.com/snappr/snappr.server/pull/1234": {
      "date": "2026-06-09",
      "dir_name": "fix-foo",
      "repo_slug": "snappr.server",
      "created_feature": true,
      "status": "active"
    }
  }
}
```

`status` is one of `active` (review session running — eligible for the cleanup
pass), `cleaned` (torn down), or `failed` (setup failed; kept only for dedupe).

If the file is missing (first run), set `last_ts` to the current epoch time
minus 600 seconds and continue — **never backfill old channel history**.

### 2. Read the channel

Call `mcp__plugin_slack_slack__slack_read_channel` for channel `GPZ71UN5B`
(recent messages). Keep only top-level messages with `ts > last_ts` whose text
contains `<@URX2NBZQD>`.

### 3. Extract PR links

From each matching message, extract **every** GitHub PR URL with:

```
https://github\.com/[^/\s<>|]+/([^/\s<>|]+)/pull/(\d+)
```

Capture group 1 = repo slug, group 2 = PR number. Slack wraps links as
`<url>` or `<url|label>` — strip the angle brackets and any `|label` suffix
before matching.

**A single message may contain multiple PR links — treat each PR URL as its
own independent work item** (own feature workspace, own cmux workspace, own
Claude session, own browser tab). Process them one at a time in order; a
failure on one PR must not stop the others.

A mention with no PR link is skipped (it still advances `last_ts` in step 5).

### 4. For each PR URL not already in `state.processed`

a. **Resolve the branch**: `gh pr view <url> --json headRefName --jq .headRefName`.
   Compute `dir_name` = branch with every `/` replaced by `-` (feature-cli does
   the same sanitization).

b. **Create the feature workspace** if `~/features/<dir_name>/` does not exist:

   ```bash
   feature from-pr <pr-url> <repo-slug>
   ```

   Passing the repo positionally keeps it non-interactive. Notes:
   - `feature from-pr` dies if the feature dir already exists — that's why we
     check first; an existing dir means reuse it, not an error.
   - If `~/.config/feature-cli/repos/<repo-slug>` does not exist, skip this
     step (no worktree), still do steps c–d with `--cwd ~/features`, and flag
     it in the summary.
   - This step can take a while (worktree + deps + post-init); that's fine.

c. **Create the cmux workspace** (skip if `cmux list-workspaces` already shows
   one named `[PR-REVIEW] <dir_name>` — reuse its ref instead):

   ```bash
   cmux new-workspace \
     --name "[PR-REVIEW] <dir_name>" \
     --cwd ~/features/<dir_name>/<repo-slug> \
     --command "cd ~/features/<dir_name>/<repo-slug> && claude \"/review <pr-url> — after the review, explain to me what the main changes are\"" \
     --focus true
   ```

   Capture the workspace ref from the `OK workspace:N` line of stdout
   (`awk '/^OK workspace:/ {print $2; exit}'`), then color it light green so
   review workspaces stand out in the sidebar:

   ```bash
   cmux workspace-action --action set-color --workspace "<ws_ref>" --color "#90EE90"
   ```

d. **Open the PR in a browser tab** in that workspace (`cmux browser open`,
   NOT `cmux open` — the latter is for files and fails with "Source surface
   not found" when called from another workspace):

   ```bash
   cmux browser open "<pr-url>" --workspace "<ws_ref>" --focus true
   ```

e. **Record it**: add the PR URL to `state.processed` as an object (see the
   schema in step 1): today's date, `dir_name`, `repo_slug`,
   `created_feature` (false if the feature dir already existed before this
   skill ran `feature from-pr`), and `status: "active"`. Record failures too
   (`status: "failed"`, with the failure noted in the summary) so the loop
   never retries the same PR forever — Nicolas handles failures manually.

### 5. Cleanup pass — tear down finished reviews

For each `state.processed` entry with `status == "active"`, check the PR:

```bash
gh pr view <pr-url> --json state,reviews \
  --jq '{state: .state, approvedByMe: ([.reviews[] | select(.author.login == "Nicomalacho" and .state == "APPROVED")] | length > 0)}'
```

If `state` is `MERGED` or `CLOSED`, **or** `approvedByMe` is true, tear the
review session down:

a. **Close the cmux workspace**: find the ref in `cmux list-workspaces` whose
   name is exactly `[PR-REVIEW] <dir_name>` (refs change across cmux restarts —
   always match by name), then:

   ```bash
   cmux close-workspace --workspace <ws_ref>
   ```

   This kills the Claude session and the browser tab. If no workspace with
   that name exists (already closed by hand), that's fine — continue.

b. **Destroy the feature** — only if `created_feature` is true (never destroy
   a feature dir this skill didn't create) and `~/features/<dir_name>/`
   exists. `feature destroy` always asks for confirmation on local features,
   so pipe the answer in:

   ```bash
   echo y | feature destroy <dir_name>
   ```

   This stops services, removes worktrees, deletes the dir, and frees the
   port allocation. If `created_feature` is false, skip the destroy and say
   so in the summary so Nicolas can clean it up himself.

c. Set the entry's `status` to `"cleaned"` (keep it in `processed` for dedupe
   until the 14-day prune). If a teardown step errors, leave `status` as
   `"active"` and report it — it will retry next iteration.

### 6. Save state

- Set `last_ts` to the newest message `ts` seen in the channel this iteration
  (advance it even when no mentions or no PR links were found).
- Prune `processed` entries older than 14 days (any status).
- Write the file back.

### 7. Report

End the iteration with a short summary, one line per outcome:

- `No new mentions; nothing to clean up.` — quiet iteration.
- `Started review session for snappr.server#1234 → cmux workspace "[PR-REVIEW] fix-foo" + PR tab.`
- `snappr.server#1234 approved by you — closed workspace "[PR-REVIEW] fix-foo" and destroyed feature fix-foo.`
- `snappr.web#88: feature from-pr failed (<one-line reason>) — handle manually; won't retry.`

## Gotchas

- Quote the claude prompt carefully inside `--command`: outer double quotes
  for the shell command string, escaped inner quotes around the prompt.
- `cmux send` treats `\n` as Enter — not used here, but if you ever fall back
  to sending into an existing surface, end the command with `$'\n'`.
- Don't run `feature start` — the goal is a review session, not booting the
  dev stack.
