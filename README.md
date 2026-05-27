# skills

Claude Code skills, version-controlled here and installable on any machine.

## Available skills

- [`babysit-pr-stack/`](./babysit-pr-stack/) — manage a stacked GitHub PR set: discover the chain, watch each PR, cascade-rebase children when an ancestor merges or moves, auto-resolve safe conflicts (lockfiles, generated files, non-overlapping additions, whitespace), and escalate risky ones (migrations, IaC, same-line edits) with a clean handoff to the user. Designed for `/loop` use against plain GitHub PRs — no graphite/spr/ghstack required.

## Install

One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/Nicomalacho/skills/main/install.sh | bash
```

This installs the default skill (`babysit-pr-stack`) into `~/.claude/skills/`. Restart Claude Code (or open a new session) afterward — skills are loaded at session start.

### Install a specific skill

```bash
curl -fsSL https://raw.githubusercontent.com/Nicomalacho/skills/main/install.sh | bash -s <skill-name>
```

### Install from a local clone

```bash
git clone https://github.com/Nicomalacho/skills.git
cd skills
./install.sh                # default skill
./install.sh <skill-name>   # specific skill
```

The installer:

- Clones this repo into a temp directory.
- Copies the requested skill folder into `~/.claude/skills/<skill-name>/`.
- If a skill with the same name is already there, backs it up to `<skill-name>.bak.<timestamp>` before overwriting.

### Updating

Re-run the one-liner. The previous install is auto-backed up.

### Uninstall

```bash
rm -rf ~/.claude/skills/<skill-name>
```

## Layout

Each top-level directory is one skill. A skill folder must contain a `SKILL.md` with YAML frontmatter (`name`, `description`). Optional siblings: `references/` for docs the skill points at, `scripts/` for executables it calls, `evals/` for test prompts, plus any skill-specific test docs.

## Contributing a skill

Drop a new top-level directory with a `SKILL.md`. Skills should:

- Be specific about *when* to trigger (the `description` field is what Claude reads to decide).
- Keep `SKILL.md` under ~500 lines; push longer content into `references/` and link from `SKILL.md`.
- Avoid heavy-handed `MUST` / `NEVER`-in-all-caps prose — explain the *why* so Claude can reason about edge cases.
