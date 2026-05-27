# skills

Personal Claude Code skills, version-controlled here and symlinked into `~/.agents/skills/` (and through there into `~/.claude/skills/`).

## Layout

Each top-level directory is one skill. The skill folder must contain a `SKILL.md` with frontmatter (`name`, `description`) at minimum. Optional siblings: `references/` for docs the skill points at, `scripts/` for executables it calls, `evals/` for test prompts, plus any skill-specific test docs.

## Current skills

- [`babysit-pr-stack/`](./babysit-pr-stack/) — manage a stacked GitHub PR set: discover the chain, watch each PR, cascade-rebase children on merge/update, auto-resolve safe conflicts and escalate the rest.

## Linking a skill into Claude Code

```
ln -s /Users/nicolasgaviria/skills/<skill-name> ~/.agents/skills/<skill-name>
```

`~/.claude/skills/<skill-name>` is usually already a symlink to the agents path. If not, mirror it.
