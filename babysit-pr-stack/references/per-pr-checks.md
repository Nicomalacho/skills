# Per-PR Check and Review Handling

Once a stack's cascade rebases are settled, each individual open PR still needs the same babysitting any single PR would get: failing-check classification, flaky retry budget, review-comment surfacing. This doc captures those patterns inline so the stack skill doesn't depend on any specific single-PR skill.

## CI failure classification

Inspect failed runs before deciding to rerun:

```bash
gh run view <run-id> --json jobs,name,workflowName,conclusion,status,url,headSha
gh api repos/<owner>/<repo>/actions/runs/<run-id>/jobs -X GET -f per_page=100
gh api repos/<owner>/<repo>/actions/jobs/<job-id>/logs > /tmp/job-<job-id>-logs.zip
gh run view <run-id> --log-failed   # fallback after the overall run finishes
```

Treat as **branch-related** when logs clearly show a regression caused by the PR's changes:
- Compile / typecheck / lint failures in files the branch touches
- Deterministic unit or integration test failures in changed areas
- Snapshot diffs caused by UI / text changes in the branch
- Static analysis violations introduced by the latest push
- Build script or config changes in the PR causing deterministic failure

Treat as **flaky or unrelated** when evidence points to transient or external issues:
- DNS / network / registry timeout errors fetching dependencies
- Runner image provisioning or startup failures
- GitHub Actions infrastructure outages
- Rate limits or transient cloud-service issues
- Known-flake non-deterministic failures in unrelated tests

**Fix branch-related failures.** Patch locally, commit, push, resume monitoring.

**Do not patch flaky / unrelated failures.** Rerun via `gh run rerun --failed` when sensible; otherwise wait or escalate. Editing unrelated tests, build scripts, CI config, or dependency pins to "fix" failures that aren't yours is a high-risk no-op.

If classification is ambiguous, inspect failed logs once before choosing rerun vs. patch.

## Flaky retry budget

Reset per SHA. Default budget: **3 reruns**.

- 1st failure on a SHA: classify, then decide rerun vs patch.
- 2nd failure after rerun: re-classify; the same job failing twice is now a likely real bug or persistent infra issue.
- 3rd failure: escalate to the user with the failed-job logs. Do not silently keep retrying.

The budget resets whenever the PR gets a new head SHA (any push, including your own rebase pushes).

## Review-comment handling

The skill should surface human review feedback that arrives during monitoring. For each new review item from another author:

- **Actionable + correct + safely fixable in this branch:** patch locally, commit, push, then mark the review thread as resolved on GitHub after the push succeeds.
- **Non-actionable, already addressed, or requires a written answer:** report to the user with the suggested response. Do **not** post replies to human-authored comments without explicit user confirmation of the exact text. If the user approves a reply, prefix with `[automated]` so it's clear the response wasn't typed by the human.
- **Already marked resolved:** ignore unless new unresolved follow-up appears.

Process review fixes **before** flaky reruns when both are present — a review fix will produce a new SHA that retriggers CI anyway.

## When to stop, not push

Stop and ask the user when:

- The worktree has unrelated uncommitted changes when you go to fix a failure.
- `gh` auth fails or the push is rejected for permission reasons.
- A persistent failure exhausts the retry budget.
- Review feedback requires a product decision or cross-team coordination.
- A human review comment needs a written GitHub reply (don't auto-reply).
