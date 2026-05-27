# Rebase Conflict Resolution

How to decide whether to auto-resolve a conflict during a cascade rebase or hand it back to the user. The cost of a wrong auto-resolve in a stack is high — bad resolutions propagate up to every PR above and produce code that compiles but is silently wrong.

## Decision principle

Auto-resolve only when the resolution is **mechanically determined** from the two sides — i.e. any competent engineer would produce the same answer without reading surrounding code. Anything that requires understanding intent goes to the user.

## File-type playbook

### Lockfiles → regenerate, don't merge

Hand-merging lockfiles produces files that don't match a real install graph and tend to break at deploy time. Instead:

| Lockfile | Regenerate command |
|---|---|
| `package-lock.json` | `rm package-lock.json && npm install` |
| `yarn.lock` | `rm yarn.lock && yarn install` |
| `pnpm-lock.yaml` | `rm pnpm-lock.yaml && pnpm install` |
| `Cargo.lock` | `rm Cargo.lock && cargo update -p $(toml-key)` or `cargo build` |
| `poetry.lock` | `rm poetry.lock && poetry lock --no-update` |
| `Gemfile.lock` | `rm Gemfile.lock && bundle install` |
| `go.sum` | `rm go.sum && go mod tidy` |
| `composer.lock` | `rm composer.lock && composer install` |

Run the regeneration **after** all source-code conflicts in the same rebase step are resolved, since lockfile contents depend on `package.json` / `Cargo.toml` / etc.

If the package manager isn't installed in the environment, escalate rather than guessing.

### Whitespace-only conflicts → format

If both sides differ only in whitespace (tabs vs spaces, trailing newlines, line endings), prefer the side that matches the project's formatter and run it:

- TypeScript/JavaScript: `prettier --write <file>` or `eslint --fix <file>`
- Python: `black <file>` or `ruff format <file>`
- Go: `gofmt -w <file>`
- Rust: `rustfmt <file>`

If no formatter is configured, take whichever side matches the surrounding file's style.

### Generated files → regenerate from source

Examples: protobuf-generated code, GraphQL codegen output, snapshot tests, OpenAPI client stubs.

Detection signals: file has a header comment like "Auto-generated, do not edit", lives in a `generated/`, `gen/`, `__generated__/`, or `*.gen.ts` path, or has a build step that produces it.

Resolution: discard the conflict markers, run the project's codegen command (typically a `Makefile` target or `npm run codegen`), commit the result.

### Non-overlapping adjacent additions → take both

When both sides added new lines at the same location but the added content is different and non-overlapping (e.g. both added a new import, both added a new test case, both added a new entry to an enum):

```
<<<<<<< HEAD
import { newThing } from './thing-a';
=======
import { otherThing } from './thing-b';
>>>>>>> their-branch
```

Resolution: keep both, in alphabetical or original-position order, drop the conflict markers.

Apply this **only** when the two additions are syntactically independent — both imports, both array entries, both top-level functions with different names. If they share a name or one shadows the other, escalate.

## Escalate to the user when

- **Overlapping edits in function bodies, conditionals, or control flow.** Even a one-line conflict in a `useEffect` dependency array or a switch statement can flip behavior. The model cannot reliably reconstruct intent from the diff alone.
- **Database migrations / schema files.** Wrong ordering or merged-in steps corrupt the migration history. Always human.
- **Infrastructure-as-code** (Terraform, Pulumi, Helm, k8s manifests) — wrong merges can take down production.
- **API contracts / schema files** — OpenAPI specs, GraphQL schemas, protobuf `.proto` files when not auto-generated, type-only `.d.ts` declarations.
- **Delete-vs-modify conflicts.** One side removed the file, the other side edited it. Ask which intent wins.
- **Rename-with-edit conflicts.** Git's rename detection can be wrong; surface the original and renamed paths so the user can verify.
- **More than ~5 hunks conflict in a single file**, even if each individual hunk looks mechanical. The risk of one being subtle outweighs the time savings.
- **Conflict markers in a binary file.** Don't try.
- **Anything in a `.github/workflows/` file**, `Dockerfile`, or CI config — wrong merges silently break the build and are easy to miss.

## Resolution workflow

For each conflicted file, after classifying:

1. If auto-resolvable: apply the resolution, `git add <file>`.
2. If escalating: leave the file with conflict markers, do **not** `git add` it.

After processing all files:

- If all conflicts were auto-resolved: `git rebase --continue`. If the rebase has more commits, more conflicts may surface — repeat.
- If any file was escalated: stop the rebase in-place (do not abort), and report to the user with:

```
Paused rebasing #126 onto feature/auth-step-2 (new SHA: <sha>).
Conflicts requiring your judgment:
  - src/db/migrations/2024_05_add_users.sql (schema file — ordering matters)
  - src/auth/session.ts (overlapping edits in refreshSession())

To inspect:
  cd <repo> && git status

To take over:
  edit the conflicted files, then `git add` them and `git rebase --continue`

To roll back:
  git rebase --abort

Resuming this skill after you finish will re-detect the new state and continue.
```

## Validation after auto-resolution

After `git rebase --continue` completes for a PR:

1. Run the project's typecheck / lint / build quickly if cheap (under ~30 s). If it fails, the auto-resolution was wrong — abort the rebase and escalate.
2. Push with `--force-with-lease`.
3. Watch CI on the new SHA; treat the first failed run after a rebase as a possible bad merge (not flaky).

Do not skip step 1 for trivial-looking resolutions. The whole point of cascade rebasing is to land code; landing broken code wastes more time than the quick check costs.

## What never to do

- `git rebase --skip` to "get past" a conflict. This drops a commit.
- `git checkout --theirs <file>` / `--ours <file>` without thinking — these silently drop one side's intent.
- `git push --force` (without `--with-lease`). If a teammate pushed in parallel, you will obliterate their work.
- `git reset --hard` mid-rebase to "start over". Use `git rebase --abort`.
